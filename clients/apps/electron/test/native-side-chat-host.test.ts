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
  sideChatClientFrameSchema,
  sideChatGeometrySettingsSchema,
  sideChatHostFrameSchema,
  type SideChatClientFrame,
  type SideChatGeometrySettings,
  type SideChatHostFrame,
} from "@comma/chat-contract";
import { defaultSideChatDebugSettings } from "@comma/native-bridge";
import { afterEach, describe, expect, it } from "vitest";
import {
  packagedSideChatHostAppPath,
  sideChatAppName,
  sideChatHostDistAppPath,
} from "../scripts/native-paths";

const appDir = resolve(import.meta.dirname, "..");
const requirePackagedHelper = process.env.COMMA_VERIFY_PACKAGED_SIDE_CHAT === "1";
const packagedElectronApp = requirePackagedHelper
  ? process.env.COMMA_ELECTRON_APP_BUNDLE ||
    findPackagedElectronApp(resolve(appDir, "out"))
  : undefined;
if (requirePackagedHelper && !packagedElectronApp) {
  throw new Error(
    `COMMA_VERIFY_PACKAGED_SIDE_CHAT=1 but no Electron app containing the packaged Side Chat helper was found under ${resolve(appDir, "out")}.`
  );
}
const helperApp = packagedElectronApp
  ? packagedSideChatHostAppPath(packagedElectronApp)
  : sideChatHostDistAppPath(appDir);
const helperExecutable = resolve(helperApp, "Contents/MacOS", sideChatAppName);
if (requirePackagedHelper && !existsSync(helperExecutable)) {
  throw new Error(
    `COMMA_VERIFY_PACKAGED_SIDE_CHAT=1 but ${packagedElectronApp} has no helper at ${helperExecutable}.`
  );
}
const canRunRealHelper = process.platform === "darwin" && existsSync(helperExecutable);
const runningHelpers = new Set<RealHelperHarness>();

afterEach(async () => {
  await Promise.all([...runningHelpers].map((helper) => helper.forceClose()));
});

describe("CommaSideChatHost gesture lifecycle", () => {
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
        { encoding: "utf8" }
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
      expect(linkedFrameworks.stdout).not.toMatch(
        /DeveloperToolsSupport|MarkdownView|SwiftUI/
      );

      if (packagedElectronApp) {
        const verify = spawnSync(
          "codesign",
          ["--verify", "--deep", "--strict", helperApp],
          { encoding: "utf8" }
        );
        expect(verify.status, verify.stderr).toBe(0);
        expect(helperApp).toContain("Contents/Resources/native/macos");
      }
    }
  );

  it.skipIf(!canRunRealHelper)(
    "emits presentation geometry and drives open/close without owning chat data or a UI window",
    async () => {
      const helper = new RealHelperHarness();

      await expect(
        helper.waitForFrame((frame) => frame.kind === "side-chat.ready")
      ).resolves.toMatchObject({
        kind: "side-chat.ready",
        protocolVersion: chatProtocolVersion,
      });
      const initial = await helper.waitForPresentation(
        (presentation) => presentation.phase === "closed"
      );
      expect(initial).toMatchObject({
        contentFrame: { height: 254, width: 364 },
        offsetX: expect.any(Number),
        progress: 0,
        windowFrame: { height: 345, width: 527 },
      });
      expect(initial.windowFrame.y).toBe(initial.screenFrame.y);
      expect(initial.contentFrame.y).toBe(
        initial.screenFrame.y + defaultSideChatDebugSettings.bottomOffset - 9
      );
      expect(initial.windowFrame.x).toBe(initial.screenFrame.x);
      expect(initial.contentFrame.x).toBe(
        initial.screenFrame.x + defaultSideChatDebugSettings.openXOffset + 5
      );

      helper.writeFrame({
        keyCode: 40,
        kind: "side-chat.shortcut",
        modifiers: 4_608,
        protocolVersion: chatProtocolVersion,
        requestId: "shortcut-control-shift-k",
      });
      await expect(
        helper.waitForResult("shortcut-control-shift-k")
      ).resolves.toMatchObject({ ok: true });

      helper.writeFrame({
        keyCode: 38,
        kind: "side-chat.shortcut",
        modifiers: 6_144,
        protocolVersion: chatProtocolVersion,
        requestId: "shortcut-control-option-j",
      });
      await expect(
        helper.waitForResult("shortcut-control-option-j")
      ).resolves.toMatchObject({ ok: true });

      helper.writeFrame({
        debugSettings: defaultGeometrySettings({ contentWidth: 400 }),
        height: 320,
        kind: "side-chat.layout",
        protocolVersion: chatProtocolVersion,
        requestId: "layout-1",
        width: 400,
      });
      await expect(helper.waitForResult("layout-1")).resolves.toMatchObject({
        ok: true,
      });
      await expect(
        helper.waitForPresentation(
          ({ contentFrame }) =>
            contentFrame.width === 400 && contentFrame.height === 320
        )
      ).resolves.toMatchObject({
        contentFrame: { height: 320, width: 400 },
        windowFrame: { height: 411, width: 563 },
      });

      helper.writeFrame({
        debugSettings: defaultGeometrySettings({
          bottomFeather: 60,
          bottomOffset: 30,
          closedExtraOffset: 30,
          contentOffsetX: -20,
          contentOffsetY: -30,
          contentWidth: 420,
          leftFeather: 50,
          openXOffset: 20,
          rightFeather: 100,
          solidOutsetBottom: 10,
          solidOutsetLeft: 10,
          solidOutsetTop: 20,
          topFeather: 40,
        }),
        height: 300,
        kind: "side-chat.layout",
        protocolVersion: chatProtocolVersion,
        requestId: "layout-debug-live",
        width: 420,
      });
      await expect(helper.waitForResult("layout-debug-live")).resolves.toMatchObject({
        ok: true,
      });
      const customized = await helper.waitForPresentation(
        ({ contentFrame }) => contentFrame.width === 420 && contentFrame.height === 300
      );
      expect(customized).toMatchObject({
        contentFrame: { height: 300, width: 420 },
        offsetX: -630,
        windowFrame: { height: 460, width: 600 },
      });
      expect(customized.windowFrame.x).toBe(customized.screenFrame.x);
      expect(customized.windowFrame.y).toBe(customized.screenFrame.y);
      expect(customized.contentFrame.x - customized.windowFrame.x).toBeCloseTo(60, 4);
      expect(customized.contentFrame.y - customized.windowFrame.y).toBeCloseTo(70, 4);

      helper.writeFrame({
        kind: "side-chat.interactive-progress",
        progress: 0.375,
        protocolVersion: chatProtocolVersion,
        requestId: "progress-open",
      });
      await expect(helper.waitForResult("progress-open")).resolves.toMatchObject({
        ok: true,
      });
      await expect(
        helper.waitForPresentation(
          ({ phase, progress }) =>
            phase === "interactive" && Math.abs(progress - 0.375) < 0.001
        )
      ).resolves.toMatchObject({
        offsetX: -(1 - 0.375) * (customized.windowFrame.width + 30),
        phase: "interactive",
        progress: 0.375,
      });

      helper.writeFrame({
        kind: "side-chat.interactive-complete",
        protocolVersion: chatProtocolVersion,
        requestId: "progress-complete-open",
        shouldOpen: true,
      });
      await expect(
        helper.waitForResult("progress-complete-open")
      ).resolves.toMatchObject({ ok: true });
      await expect(
        helper.waitForPresentation((presentation) => presentation.phase === "open")
      ).resolves.toMatchObject({ offsetX: 0, progress: 1 });

      helper.writeFrame({
        kind: "side-chat.interactive-progress",
        progress: 0.375,
        protocolVersion: chatProtocolVersion,
        requestId: "progress-close",
      });
      await expect(helper.waitForResult("progress-close")).resolves.toMatchObject({
        ok: true,
      });
      await expect(
        helper.waitForPresentation(
          ({ phase, progress }) =>
            phase === "interactive" && Math.abs(progress - 0.375) < 0.001
        )
      ).resolves.toMatchObject({ phase: "interactive", progress: 0.375 });

      helper.writeFrame({
        kind: "side-chat.interactive-complete",
        protocolVersion: chatProtocolVersion,
        requestId: "progress-complete-closed",
        shouldOpen: false,
      });
      await expect(
        helper.waitForResult("progress-complete-closed")
      ).resolves.toMatchObject({ ok: true });
      await expect(
        helper.waitForPresentation((presentation) => presentation.phase === "closed")
      ).resolves.toMatchObject({ progress: 0 });

      helper.writeFrame(controlFrame("side-chat.open", "open-1"));
      await expect(helper.waitForResult("open-1")).resolves.toMatchObject({ ok: true });
      const opened = await helper.waitForPresentation(
        (presentation) => presentation.phase === "open"
      );
      expect(opened).toMatchObject({ offsetX: 0, progress: 1 });

      // Renderer pointermove and pointerup can cross the generated bridge in
      // the same run-loop turn. Completion must flush the latest pending
      // progress before settling, rather than jumping back to the old endpoint.
      helper.writeFrame({
        kind: "side-chat.interactive-progress",
        progress: 0.25,
        protocolVersion: chatProtocolVersion,
        requestId: "burst-progress",
      });
      helper.writeFrame({
        kind: "side-chat.interactive-complete",
        protocolVersion: chatProtocolVersion,
        requestId: "burst-complete",
        shouldOpen: false,
      });
      await expect(helper.waitForResult("burst-progress")).resolves.toMatchObject({
        ok: true,
      });
      await expect(helper.waitForResult("burst-complete")).resolves.toMatchObject({
        ok: true,
      });
      const burstClosing = await helper.waitForPresentation(
        (presentation) =>
          presentation.phase === "closing" && presentation.revision > opened.revision
      );
      expect(burstClosing.progress).toBeGreaterThan(0.15);
      expect(burstClosing.progress).toBeLessThan(0.35);
      const burstClosed = await helper.waitForPresentation(
        (presentation) => presentation.phase === "closed"
      );
      expect(burstClosed).toMatchObject({ progress: 0 });

      helper.writeFrame(controlFrame("side-chat.open", "force-close-setup"));
      await expect(helper.waitForResult("force-close-setup")).resolves.toMatchObject({
        ok: true,
      });
      const forceCloseOpened = await helper.waitForPresentation(
        (presentation) =>
          presentation.phase === "open" && presentation.revision > burstClosed.revision
      );

      // A Main-owned close is a causal fence. Back-to-back local-style open,
      // toggle, and trackpad commands may still be acknowledged, but none may
      // cancel the forced close before its terminal presentation is emitted.
      const closeFrameStart = helper.observedFrames().length;
      helper.writeFrame(controlFrame("side-chat.close", "close-1"));
      helper.writeFrame(controlFrame("side-chat.open", "close-race-open"));
      helper.writeFrame(controlFrame("side-chat.toggle", "close-race-toggle"));
      helper.writeFrame({
        kind: "side-chat.interactive-progress",
        progress: 0.9,
        protocolVersion: chatProtocolVersion,
        requestId: "close-race-progress",
      });
      helper.writeFrame({
        kind: "side-chat.interactive-complete",
        protocolVersion: chatProtocolVersion,
        requestId: "close-race-complete",
        shouldOpen: true,
      });
      await expect(helper.waitForResult("close-1")).resolves.toMatchObject({
        ok: true,
      });
      for (const requestId of [
        "close-race-open",
        "close-race-toggle",
        "close-race-progress",
        "close-race-complete",
      ]) {
        await expect(helper.waitForResult(requestId)).resolves.toMatchObject({
          ok: true,
        });
      }
      const closed = await helper.waitForPresentation(
        (presentation) =>
          presentation.phase === "closed" &&
          presentation.revision > forceCloseOpened.revision
      );
      expect(closed.progress).toBe(0);
      expect(closed.offsetX).toBeLessThan(-closed.windowFrame.width);
      const closeFrames = helper.observedFrames().slice(closeFrameStart);
      const closeResultIndex = closeFrames.findIndex(
        (frame) => frame.kind === "command.result" && frame.requestId === "close-1"
      );
      const terminalClosedIndex = closeFrames.findIndex(
        (frame) =>
          frame.kind === "side-chat.presentation" && frame.revision === closed.revision
      );
      expect(closeResultIndex).toBeGreaterThanOrEqual(0);
      expect(terminalClosedIndex).toBeGreaterThan(closeResultIndex);
      const forcedClosePresentations = closeFrames.filter(
        (frame) => frame.kind === "side-chat.presentation"
      );
      expect(forcedClosePresentations.length).toBeGreaterThan(1);
      expect(
        forcedClosePresentations.every(
          (presentation) =>
            presentation.phase === "closing" ||
            (presentation.phase === "closed" &&
              presentation.revision === closed.revision)
        )
      ).toBe(true);

      helper.writeFrame(controlFrame("side-chat.open", "open-after-forced-close"));
      await expect(
        helper.waitForResult("open-after-forced-close")
      ).resolves.toMatchObject({ ok: true });
      await expect(
        helper.waitForPresentation(
          (presentation) =>
            presentation.phase === "open" && presentation.revision > closed.revision
        )
      ).resolves.toMatchObject({ offsetX: 0, progress: 1 });

      expect(
        helper.observedFrames().some((frame) => frame.kind.startsWith("chat."))
      ).toBe(false);
      await expect(helper.close()).resolves.toEqual({ code: 0, signal: null });
    },
    20_000
  );

  it.skipIf(!canRunRealHelper)(
    "fails closed on version mismatches and out-of-range interactive progress",
    async () => {
      const helper = new RealHelperHarness();
      await helper.waitForFrame((frame) => frame.kind === "side-chat.ready");

      helper.writeRawFrame({
        kind: "side-chat.open",
        protocolVersion: chatProtocolVersion + 1,
        requestId: "wrong-version",
      });

      await expect(
        helper.waitForFrame((frame) => frame.kind === "side-chat.protocol-error")
      ).resolves.toMatchObject({
        expectedProtocolVersion: chatProtocolVersion,
        frameKind: "side-chat.open",
        kind: "side-chat.protocol-error",
        receivedProtocolVersion: chatProtocolVersion + 1,
      });
      await helper.expectNoResult("wrong-version", 300);

      helper.writeRawFrame({
        kind: "side-chat.interactive-progress",
        progress: 1.001,
        protocolVersion: chatProtocolVersion,
        requestId: "out-of-range-progress",
      });
      await expect(
        helper.waitForFrame(
          (frame) =>
            frame.kind === "side-chat.protocol-error" &&
            frame.frameKind === "side-chat.interactive-progress"
        )
      ).resolves.toMatchObject({
        expectedProtocolVersion: chatProtocolVersion,
        frameKind: "side-chat.interactive-progress",
        kind: "side-chat.protocol-error",
        receivedProtocolVersion: chatProtocolVersion,
      });
      await helper.expectNoResult("out-of-range-progress", 300);
      await expect(helper.close()).resolves.toEqual({ code: 0, signal: null });
    },
    10_000
  );

  it.skipIf(!canRunRealHelper)(
    "exits when Electron closes its stdin",
    async () => {
      const helper = new RealHelperHarness();
      await expect(helper.close()).resolves.toEqual({ code: 0, signal: null });
    },
    10_000
  );
});

describe("packaged Side Chat discovery", () => {
  it("finds the Electron bundle by its nested helper instead of its product name", () => {
    const root = mkdtempSync(resolve(tmpdir(), "comma-side-chat-package-"));
    const electronApp = resolve(root, "Renamed Product.app");
    const nestedHelperExecutable = resolve(
      packagedSideChatHostAppPath(electronApp),
      "Contents/MacOS",
      sideChatAppName
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

function controlFrame(
  kind: "side-chat.close" | "side-chat.open" | "side-chat.toggle",
  requestId: string
): SideChatHostFrame {
  return sideChatHostFrameSchema.parse({
    kind,
    protocolVersion: chatProtocolVersion,
    requestId,
  });
}

function findPackagedElectronApp(root: string): string | undefined {
  if (!existsSync(root)) return undefined;
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const path = resolve(root, entry.name);
    if (entry.name.endsWith(".app")) {
      const nestedHelper = packagedSideChatHostAppPath(path);
      if (existsSync(resolve(nestedHelper, "Contents/MacOS", sideChatAppName))) {
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
  predicate: (frame: SideChatClientFrame) => boolean;
  reject(error: Error): void;
  resolve(frame: SideChatClientFrame): void;
  timer: ReturnType<typeof setTimeout>;
};

class FrameTimeoutError extends Error {}

class RealHelperHarness {
  readonly #exitPromise: Promise<ExitResult>;
  readonly #frames: SideChatClientFrame[] = [];
  readonly #host: ChildProcessWithoutNullStreams;
  readonly #observed: SideChatClientFrame[] = [];
  readonly #waiters = new Set<FrameWaiter>();
  #fatalError: Error | undefined;
  #stderr = "";
  #stdoutBuffer = "";

  constructor() {
    this.#host = spawn(helperExecutable, [], {
      env: cleanHelperEnvironment(process.env),
      stdio: ["pipe", "pipe", "pipe"],
    });
    runningHelpers.add(this);
    this.#host.stdout.on("data", (chunk) => this.#acceptStdout(chunk.toString()));
    this.#host.stderr.on("data", (chunk) => {
      this.#stderr += chunk.toString();
    });
    this.#host.once("error", (error) => this.#fail(error));
    this.#exitPromise = new Promise((resolveExit) => {
      this.#host.once("exit", (code, signal) => {
        runningHelpers.delete(this);
        resolveExit({ code, signal });
      });
    });
  }

  observedFrames() {
    return [...this.#observed];
  }

  writeFrame(frame: SideChatHostFrame) {
    this.writeRawFrame(sideChatHostFrameSchema.parse(frame));
  }

  writeRawFrame(frame: unknown) {
    this.#host.stdin.write(`${JSON.stringify(frame)}\n`);
  }

  waitForResult(requestId: string) {
    return this.waitForFrame(
      (frame) => frame.kind === "command.result" && frame.requestId === requestId
    );
  }

  waitForPresentation(
    predicate: (
      frame: Extract<SideChatClientFrame, { kind: "side-chat.presentation" }>
    ) => boolean
  ) {
    return this.waitForFrame(
      (frame) => frame.kind === "side-chat.presentation" && predicate(frame)
    ) as Promise<Extract<SideChatClientFrame, { kind: "side-chat.presentation" }>>;
  }

  waitForFrame(
    predicate: (frame: SideChatClientFrame) => boolean,
    timeoutMs = 5_000
  ): Promise<SideChatClientFrame> {
    const queuedIndex = this.#frames.findIndex(predicate);
    if (queuedIndex >= 0)
      return Promise.resolve(this.#frames.splice(queuedIndex, 1)[0]!);
    if (this.#fatalError) return Promise.reject(this.#fatalError);

    return new Promise((resolveFrame, rejectFrame) => {
      const waiter: FrameWaiter = {
        predicate,
        reject: rejectFrame,
        resolve: resolveFrame,
        timer: setTimeout(() => {
          this.#waiters.delete(waiter);
          rejectFrame(
            new FrameTimeoutError(
              `Timed out waiting for CommaSideChatHost frame. Seen: ${JSON.stringify(this.#observed)}.${this.#stderr ? ` stderr: ${this.#stderr.trim()}` : ""}`
            )
          );
        }, timeoutMs),
      };
      this.#waiters.add(waiter);
    });
  }

  async expectNoResult(requestId: string, durationMs: number) {
    try {
      const frame = await this.#waitForResultWithTimeout(requestId, durationMs);
      throw new Error(`Received unexpected result: ${JSON.stringify(frame)}`);
    } catch (error) {
      if (error instanceof FrameTimeoutError) return;
      throw error;
    }
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

      const parsed = sideChatClientFrameSchema.safeParse(JSON.parse(line) as unknown);
      if (!parsed.success) {
        this.#fail(
          new Error(
            `CommaSideChatHost emitted non-canonical JSON: ${parsed.error.message}`
          )
        );
        continue;
      }
      this.#acceptFrame(parsed.data);
    }
  }

  #acceptFrame(frame: SideChatClientFrame) {
    this.#observed.push(frame);
    const waiter = [...this.#waiters].find(({ predicate }) => predicate(frame));
    if (!waiter) {
      this.#frames.push(frame);
      return;
    }
    clearTimeout(waiter.timer);
    this.#waiters.delete(waiter);
    waiter.resolve(frame);
  }

  #fail(error: Error) {
    this.#fatalError ??= error;
    for (const waiter of this.#waiters) {
      clearTimeout(waiter.timer);
      waiter.reject(this.#fatalError);
    }
    this.#waiters.clear();
  }

  #waitForResultWithTimeout(requestId: string, timeoutMs: number) {
    return this.waitForFrame(
      (frame) => frame.kind === "command.result" && frame.requestId === requestId,
      timeoutMs
    );
  }

  async #awaitExit() {
    let timeout: ReturnType<typeof setTimeout> | undefined;
    try {
      const result = await Promise.race([
        this.#exitPromise,
        new Promise<never>((_resolve, reject) => {
          timeout = setTimeout(() => {
            this.#host.kill();
            reject(
              new Error(
                `CommaSideChatHost did not exit after stdin closed.${this.#stderr ? ` ${this.#stderr.trim()}` : ""}`
              )
            );
          }, 5_000);
        }),
      ]);
      if (this.#fatalError) throw this.#fatalError;
      return result;
    } finally {
      if (timeout) clearTimeout(timeout);
    }
  }
}

function cleanHelperEnvironment(source: NodeJS.ProcessEnv) {
  const environment: NodeJS.ProcessEnv = {};
  for (const key of ["LANG", "LC_ALL", "LC_CTYPE", "PATH"] as const) {
    if (source[key] !== undefined) environment[key] = source[key];
  }
  return environment;
}

function defaultGeometrySettings(overrides: Partial<SideChatGeometrySettings> = {}) {
  return sideChatGeometrySettingsSchema.parse({
    ...defaultSideChatDebugSettings,
    ...overrides,
  });
}
