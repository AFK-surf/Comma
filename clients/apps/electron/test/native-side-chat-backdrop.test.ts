import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { resolve } from "node:path";

import { tmpdir } from "node:os";

import { assert, describe, expect, it } from "vitest";
import { defaultSideChatDebugSettings } from "@comma/native-bridge";

const appDir = resolve(import.meta.dirname, "..");
const electronExecutable = resolve(appDir, "../../../node_modules/.bin/electron");
const fixturePath = resolve(
  import.meta.dirname,
  "fixtures/side-chat-backdrop-lifecycle.cjs"
);
const addonCandidates = [
  process.env.COMMA_SIDE_CHAT_BACKDROP_PATH,
  resolve(
    appDir,
    "native/macos/SideChatBackdrop/build/Debug/comma_side_chat_backdrop.node"
  ),
  resolve(
    appDir,
    "native/macos/SideChatBackdrop/build/Release/comma_side_chat_backdrop.node"
  ),
  resolve(appDir, "dist/native/macos/comma-side-chat-backdrop.node"),
].filter((candidate): candidate is string => Boolean(candidate));
const addonPath = addonCandidates.find(existsSync);
const canRunRealBackdrop =
  process.platform === "darwin" &&
  existsSync(electronExecutable) &&
  addonPath !== undefined;

type BackdropDiagnostics = {
  alignmentError: number;
  backdropPixels: {
    blurRadius: number;
    tintOpacity: number;
    maxAlpha: number;
    rightEdgeMaxAlpha: number;
    opaqueCoverage: {
      centerAlpha: number;
      edgeMaxAlpha: { left: number; right: number; top: number; bottom: number };
      bottomGradientPoints: number;
    };
    mask: {
      centerAlpha: number;
      edgeMaxAlpha: { left: number; right: number; top: number; bottom: number };
      leftGradientPoints: number;
      bottomGradientPoints: number;
    };
  }[];
  orderedBelowContent: boolean;
  textInputLevels: {
    class: string;
    window: number;
    responds: boolean;
    reported: number;
  }[];
};

type BackdropLifecycleResult = {
  afterReload: BackdropDiagnostics;
  afterRendererRecovery: BackdropDiagnostics;
  attached: boolean;
  blurred: BackdropDiagnostics;
  blurredAvailable: boolean;
  clippedOrigin: BackdropDiagnostics;
  dimmed: BackdropDiagnostics;
  dimmedAvailable: boolean;
  feathered: BackdropDiagnostics;
  featheredAvailable: boolean;
  ignoringMouseEventsAfterDetach: boolean;
  initial: BackdropDiagnostics;
  opened: BackdropDiagnostics;
  rebuildAvailable: boolean;
  rebuildRevisionAfter: number;
  rebuildRevisionBefore: number;
  rebuilt: BackdropDiagnostics;
  resized: BackdropDiagnostics;
  tinted: BackdropDiagnostics;
  tintedAvailable: boolean;
  untinted: BackdropDiagnostics;
  untintedAvailable: boolean;
};

describe("native Side Chat backdrop lifecycle", () => {
  it.skipIf(!canRunRealBackdrop)(
    "applies live tint and blur updates while keeping the backdrop aligned",
    async () => {
      const directory = mkdtempSync(resolve(tmpdir(), "comma-ime-probe-"));
      const probePath = resolve(directory, "probe.node");
      try {
        const makefile = readFileSync(
          resolve(
            appDir,
            "native/macos/SideChatBackdrop/build/comma_side_chat_backdrop.target.mk"
          ),
          "utf8"
        );
        const headers = makefile.match(/-I([^\n]+\/include\/node)/)?.[1];
        if (!headers)
          throw new Error(
            "Build the Side Chat addon before the native input regression."
          );
        const compile = spawnSync(
          "clang++",
          [
            "-std=c++20",
            "-fobjc-arc",
            "-bundle",
            "-undefined",
            "dynamic_lookup",
            `-I${headers}`,
            "-framework",
            "AppKit",
            "-framework",
            "QuartzCore",
            resolve(appDir, "test/fixtures/side-chat-text-input-probe.mm"),
            "-o",
            probePath,
          ],
          { encoding: "utf8" }
        );
        expect(compile.status, compile.stderr).toBe(0);
        const result = await runLifecycleFixture(addonPath!, probePath);

        expect(result.attached).toBe(true);
        expect(result.rebuildAvailable).toBe(true);
        expect(result.rebuildRevisionAfter).toBeGreaterThan(
          result.rebuildRevisionBefore
        );
        expect(result.untintedAvailable).toBe(true);
        expect(result.tintedAvailable).toBe(true);
        expect(result.blurredAvailable).toBe(true);
        expect(result.dimmedAvailable).toBe(true);
        expect(result.featheredAvailable).toBe(true);
        const coverage = singleBackdrop(result.opened).opaqueCoverage;
        expect(coverage.centerAlpha).toBe(255);
        expect(coverage.edgeMaxAlpha).toEqual({
          left: 0,
          right: 0,
          top: 0,
          bottom: 0,
        });
        expect(coverage.bottomGradientPoints).toBeGreaterThan(
          defaultSideChatDebugSettings.bottomFeather / 2
        );
        const initialBackdrop = singleBackdrop(result.initial);
        const dimmedBackdrop = singleBackdrop(result.dimmed);
        const featheredBackdrop = singleBackdrop(result.feathered);
        const untintedBackdrop = singleBackdrop(result.untinted);
        const tintedBackdrop = singleBackdrop(result.tinted);
        const blurredBackdrop = singleBackdrop(result.blurred);
        expect(untintedBackdrop.tintOpacity).toBe(0);
        expect(tintedBackdrop.tintOpacity).toBeCloseTo(0.35);
        expect(tintedBackdrop.blurRadius).toBe(initialBackdrop.blurRadius);
        expect(blurredBackdrop.blurRadius).toBe(60);
        expect(blurredBackdrop.tintOpacity).toBe(tintedBackdrop.tintOpacity);
        // Effect opacity must dim the tint without changing the fade shape.
        expect(dimmedBackdrop.mask).toEqual(initialBackdrop.mask);
        expect(dimmedBackdrop.blurRadius).toBe(initialBackdrop.blurRadius);
        expect(
          Math.abs(dimmedBackdrop.maxAlpha - initialBackdrop.maxAlpha * 0.4)
        ).toBeLessThanOrEqual(1);
        expect(dimmedBackdrop.maxAlpha).toBeLessThan(initialBackdrop.maxAlpha);
        expect(featheredBackdrop.blurRadius).toBe(initialBackdrop.blurRadius);
        expect(featheredBackdrop.mask.bottomGradientPoints).toBeGreaterThan(
          initialBackdrop.mask.bottomGradientPoints * 1.8
        );
        for (const diagnostics of [result.initial, result.clippedOrigin]) {
          // Inspect the shared opacity mask applied to the native composition.
          // These values do not prove WindowServer's final desktop appearance.
          const mask = singleBackdrop(diagnostics).mask;
          expect.soft(mask.centerAlpha).toBe(255);
          expect.soft(mask.edgeMaxAlpha).toEqual({
            left: 0,
            right: 0,
            top: 0,
            bottom: 0,
          });
          expect
            .soft(mask.leftGradientPoints)
            .toBeGreaterThan(defaultSideChatDebugSettings.leftFeather / 2);
          expect
            .soft(mask.bottomGradientPoints)
            .toBeGreaterThan(defaultSideChatDebugSettings.bottomFeather / 2);
        }
        for (const diagnostics of [
          result.initial,
          result.rebuilt,
          result.resized,
          result.afterReload,
          result.afterRendererRecovery,
          result.tinted,
          result.blurred,
          result.clippedOrigin,
        ]) {
          expect(diagnostics.alignmentError).toBeLessThanOrEqual(0.5);
          expect(diagnostics.orderedBelowContent).toBe(true);
          const backdrop = singleBackdrop(diagnostics);
          expect(backdrop.opaqueCoverage.edgeMaxAlpha.right).toBe(0);
          expect(backdrop.opaqueCoverage.edgeMaxAlpha.bottom).toBe(0);
          expect(backdrop.maxAlpha).toBeGreaterThan(0);
          expect(backdrop.rightEdgeMaxAlpha).toBe(0);
          expect(diagnostics.textInputLevels.length).toBeGreaterThan(0);
          for (const client of diagnostics.textInputLevels) {
            expect(client.window).toBe(21);
            expect(client.responds).toBe(true);
            expect(client.reported).toBe(client.window);
          }
        }
        expect(result.ignoringMouseEventsAfterDetach).toBe(false);
      } finally {
        rmSync(directory, { recursive: true, force: true });
      }
    },
    30_000
  );
});

function singleBackdrop(diagnostics: BackdropDiagnostics) {
  expect(diagnostics.backdropPixels).toHaveLength(1);
  const [backdrop] = diagnostics.backdropPixels;
  assert(backdrop, "The native probe must return a backdrop.");
  return backdrop;
}

function runLifecycleFixture(binaryPath: string, probePath: string) {
  return new Promise<BackdropLifecycleResult>((resolveResult, rejectResult) => {
    const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...environment } = process.env;
    const child = spawn(electronExecutable, [fixturePath], {
      env: {
        ...environment,
        COMMA_SIDE_CHAT_BACKDROP_PATH: binaryPath,
        COMMA_SIDE_CHAT_INPUT_PROBE_PATH: probePath,
        COMMA_SIDE_CHAT_DEBUG_DEFAULTS: JSON.stringify(defaultSideChatDebugSettings),
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stderr = "";
    let stdout = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.on("error", rejectResult);
    child.on("exit", (code, signal) => {
      if (code !== 0) {
        rejectResult(
          new Error(`Backdrop lifecycle fixture failed (${code ?? signal}).\n${stderr}`)
        );
        return;
      }

      const line = stdout
        .split("\n")
        .find((candidate) => candidate.startsWith("COMMA_SIDE_CHAT_BACKDROP_RESULT "));
      if (!line) {
        rejectResult(
          new Error(`Backdrop lifecycle fixture returned no result.\n${stderr}`)
        );
        return;
      }
      resolveResult(
        JSON.parse(
          line.slice("COMMA_SIDE_CHAT_BACKDROP_RESULT ".length)
        ) as BackdropLifecycleResult
      );
    });
  });
}
