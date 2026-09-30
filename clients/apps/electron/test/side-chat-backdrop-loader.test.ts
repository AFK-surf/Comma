import { resolve } from "node:path";

import { describe, expect, it, vi } from "vitest";

import {
  loadSideChatBackdropAddon,
  sideChatBackdropAddonFileName,
  sideChatBackdropCandidateBinaryPaths,
} from "../native/macos/SideChatBackdrop";

describe("Side Chat backdrop addon candidate paths", () => {
  const cwd = "/untrusted/development-checkout";
  const environmentPath = "/untrusted/environment/backdrop.node";
  const explicitPath = "/trusted/explicit/backdrop.node";
  const resourcesPath = "/Applications/Comma.app/Contents/Resources";
  const packagedResourcePath = resolve(
    resourcesPath,
    "native/macos",
    sideChatBackdropAddonFileName
  );

  it("treats an explicit packaged path as an exclusive fail-closed override", () => {
    expect(
      sideChatBackdropCandidateBinaryPaths({
        cwd,
        environmentPath,
        explicitPath,
        isPackaged: true,
        resourcesPath,
      })
    ).toEqual([explicitPath]);
  });

  it("does not fall back to environment or working-directory paths when packaged", () => {
    const candidates = sideChatBackdropCandidateBinaryPaths({
      cwd,
      environmentPath,
      isPackaged: true,
      resourcesPath,
    });

    expect(candidates).toEqual([packagedResourcePath]);
    expect(candidates).not.toContain(environmentPath);
    expect(candidates.some((candidate) => candidate.startsWith(cwd))).toBe(false);
  });

  it("treats an explicit development path as an exclusive fail-closed override", () => {
    const candidates = sideChatBackdropCandidateBinaryPaths({
      cwd,
      environmentPath,
      explicitPath,
      isPackaged: false,
      resourcesPath,
    });

    expect(candidates).toEqual([explicitPath]);
  });

  it("treats the development environment path as an exclusive override", () => {
    expect(
      sideChatBackdropCandidateBinaryPaths({
        cwd,
        environmentPath,
        isPackaged: false,
        resourcesPath,
      })
    ).toEqual([environmentPath]);
  });

  it("keeps resources and working-directory discovery paths in development without an override", () => {
    const candidates = sideChatBackdropCandidateBinaryPaths({
      cwd,
      environmentPath: "",
      isPackaged: false,
      resourcesPath,
    });

    expect(candidates[0]).toBe(packagedResourcePath);
    expect(candidates).toContain(
      resolve(cwd, "dist/native/macos", sideChatBackdropAddonFileName)
    );
    expect(candidates).toContain(
      resolve(
        cwd,
        "clients/apps/electron/native/macos/SideChatBackdrop/build/Debug/comma_side_chat_backdrop.node"
      )
    );
    expect(candidates).toContain(
      resolve(
        cwd,
        "clients/apps/electron/native/macos/SideChatBackdrop/build/Release/comma_side_chat_backdrop.node"
      )
    );
  });

  it("rejects an addon that cannot report native backdrop health", () => {
    const logger = { warn: vi.fn() };
    const addon = loadSideChatBackdropAddon({
      binaryPath: resolve(
        process.cwd(),
        "apps/electron/test/fixtures/side-chat-backdrop-missing-health.cjs"
      ),
      logger,
      platform: "darwin",
    });

    expect(addon.loaded).toBe(false);
    expect(addon.isAvailable()).toBe(false);
    expect(addon.loadError?.message).toContain("has an invalid API");
    expect(logger.warn).toHaveBeenCalled();
  });
});
