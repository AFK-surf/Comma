import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import type { SideChatDebugSettingsValues } from "@comma/chat-contract";

export const sideChatBackdropAddonFileName = "comma-side-chat-backdrop.node";

export type SideChatBackdropGeometry = {
  windowWidth: number;
  windowHeight: number;
  contentX: number;
  contentY: number;
  contentWidth: number;
  contentHeight: number;
  visualWidth: number;
  visualHeight: number;
};

type NativeSideChatBackdropAddon = {
  disableWindowAnimations(handle: Buffer): void;
  attach(handle: Buffer): boolean;
  isAvailable(): boolean;
  isIgnoringMouseEvents?(): boolean;
  isOrderedBelowContentSurfaces?(): boolean;
  maximumRevealAlignmentError?(): number;
  rebuildRevision?(): number;
  updateSettings(settings: SideChatDebugSettingsValues): boolean;
  updateGeometry(geometry: SideChatBackdropGeometry): boolean;
  setRevealOffset(offsetX: number): boolean;
  rebuild(): boolean;
  detach(): void;
};

export type SideChatBackdropAddon = NativeSideChatBackdropAddon & {
  readonly loaded: boolean;
  readonly binaryPath?: string;
  readonly loadError?: Error;
  isAvailable(): boolean;
  isIgnoringMouseEvents(): boolean;
  isOrderedBelowContentSurfaces(): boolean;
  maximumRevealAlignmentError(): number;
  rebuildRevision(): number;
};

type LoadSideChatBackdropAddonOptions = {
  binaryPath?: string;
  isPackaged?: boolean;
  logger?: Pick<Console, "warn">;
  platform?: NodeJS.Platform;
};

function asError(error: unknown) {
  return error instanceof Error ? error : new Error(String(error));
}

function isNativeAddon(value: unknown): value is NativeSideChatBackdropAddon {
  if (typeof value !== "object" || value === null) {
    return false;
  }

  const candidate = value as Partial<NativeSideChatBackdropAddon>;
  return (
    typeof candidate.attach === "function" &&
    typeof candidate.isAvailable === "function" &&
    typeof candidate.updateSettings === "function" &&
    typeof candidate.updateGeometry === "function" &&
    typeof candidate.setRevealOffset === "function" &&
    typeof candidate.rebuild === "function" &&
    typeof candidate.detach === "function"
  );
}

export function sideChatBackdropCandidateBinaryPaths({
  cwd = process.cwd(),
  environmentPath = process.env.COMMA_SIDE_CHAT_BACKDROP_PATH,
  explicitPath,
  isPackaged = false,
  resourcesPath = (process as NodeJS.Process & { resourcesPath?: string })
    .resourcesPath,
}: {
  cwd?: string;
  environmentPath?: string;
  explicitPath?: string;
  isPackaged?: boolean;
  resourcesPath?: string;
} = {}) {
  // Explicit/test and environment overrides are exclusive. If an operator
  // points Comma at an incompatible binary, silently falling through to another
  // addon would make the native-quality floor appear healthy by accident.
  if (explicitPath) return [explicitPath];
  if (!isPackaged && environmentPath) return [environmentPath];

  const resourcesCandidate = resourcesPath
    ? resolve(resourcesPath, "native/macos", sideChatBackdropAddonFileName)
    : undefined;
  if (isPackaged) return resourcesCandidate ? [resourcesCandidate] : [];

  const developmentCandidates = [
    resourcesCandidate,
    resolve(cwd, "dist/native/macos", sideChatBackdropAddonFileName),
    resolve(cwd, "apps/electron/dist/native/macos", sideChatBackdropAddonFileName),
    resolve(
      cwd,
      "native/macos/SideChatBackdrop/build/Debug/comma_side_chat_backdrop.node"
    ),
    resolve(
      cwd,
      "apps/electron/native/macos/SideChatBackdrop/build/Debug/comma_side_chat_backdrop.node"
    ),
    resolve(
      cwd,
      "clients/apps/electron/native/macos/SideChatBackdrop/build/Debug/comma_side_chat_backdrop.node"
    ),
    resolve(
      cwd,
      "native/macos/SideChatBackdrop/build/Release/comma_side_chat_backdrop.node"
    ),
    resolve(
      cwd,
      "apps/electron/native/macos/SideChatBackdrop/build/Release/comma_side_chat_backdrop.node"
    ),
    resolve(
      cwd,
      "clients/apps/electron/native/macos/SideChatBackdrop/build/Release/comma_side_chat_backdrop.node"
    ),
  ];
  return [
    ...new Set(developmentCandidates.filter((path): path is string => Boolean(path))),
  ];
}

function makeUnavailableAddon(error: Error): SideChatBackdropAddon {
  return {
    loaded: false,
    loadError: error,
    disableWindowAnimations: () => {
      throw error;
    },
    attach: () => false,
    isAvailable: () => false,
    isIgnoringMouseEvents: () => false,
    isOrderedBelowContentSurfaces: () => false,
    maximumRevealAlignmentError: () => Number.POSITIVE_INFINITY,
    rebuildRevision: () => 0,
    updateSettings: () => false,
    updateGeometry: () => false,
    setRevealOffset: () => false,
    rebuild: () => false,
    detach: () => undefined,
  };
}

export function loadSideChatBackdropAddon(
  options: LoadSideChatBackdropAddonOptions = {}
): SideChatBackdropAddon {
  if ((options.platform ?? process.platform) !== "darwin") {
    return makeUnavailableAddon(
      new Error("The Side Chat backdrop addon is only available on macOS.")
    );
  }

  // Electron Forge bundles Main as CommonJS, where Vite replaces `import.meta`
  // with an empty object. The addon paths below are absolute, so a stable
  // absolute synthetic filename is sufficient as createRequire's resolution
  // base in both the source-test and bundled runtimes.
  const require = createRequire(
    resolve(process.cwd(), "comma-side-chat-backdrop-loader.cjs")
  );
  const candidates = sideChatBackdropCandidateBinaryPaths({
    ...(options.binaryPath !== undefined ? { explicitPath: options.binaryPath } : {}),
    ...(options.isPackaged !== undefined ? { isPackaged: options.isPackaged } : {}),
  });
  let lastError: Error | undefined;

  for (const binaryPath of candidates) {
    if (!existsSync(binaryPath)) {
      continue;
    }

    try {
      const nativeAddon: unknown = require(binaryPath);
      if (!isNativeAddon(nativeAddon)) {
        throw new Error(
          `Side Chat backdrop addon at ${binaryPath} has an invalid API.`
        );
      }

      return {
        loaded: true,
        binaryPath,
        disableWindowAnimations: (handle) =>
          nativeAddon.disableWindowAnimations(handle),
        attach(handle) {
          try {
            return nativeAddon.attach(handle);
          } catch (error) {
            options.logger?.warn("[side-chat-backdrop] attach failed", asError(error));
            return false;
          }
        },
        isAvailable() {
          try {
            return nativeAddon.isAvailable();
          } catch (error) {
            options.logger?.warn(
              "[side-chat-backdrop] availability query failed",
              asError(error)
            );
            return false;
          }
        },
        isIgnoringMouseEvents() {
          try {
            return nativeAddon.isIgnoringMouseEvents?.() ?? false;
          } catch (error) {
            options.logger?.warn(
              "[side-chat-backdrop] mouse pass-through query failed",
              asError(error)
            );
            return false;
          }
        },
        isOrderedBelowContentSurfaces() {
          try {
            return nativeAddon.isOrderedBelowContentSurfaces?.() ?? false;
          } catch (error) {
            options.logger?.warn(
              "[side-chat-backdrop] native z-order query failed",
              asError(error)
            );
            return false;
          }
        },
        maximumRevealAlignmentError() {
          try {
            return (
              nativeAddon.maximumRevealAlignmentError?.() ?? Number.POSITIVE_INFINITY
            );
          } catch (error) {
            options.logger?.warn(
              "[side-chat-backdrop] reveal alignment query failed",
              asError(error)
            );
            return Number.POSITIVE_INFINITY;
          }
        },
        rebuildRevision() {
          try {
            return nativeAddon.rebuildRevision?.() ?? 0;
          } catch (error) {
            options.logger?.warn(
              "[side-chat-backdrop] rebuild revision query failed",
              asError(error)
            );
            return 0;
          }
        },
        updateSettings(settings) {
          try {
            return nativeAddon.updateSettings(settings);
          } catch (error) {
            options.logger?.warn(
              "[side-chat-backdrop] settings update failed",
              asError(error)
            );
            return false;
          }
        },
        updateGeometry(geometry) {
          try {
            return nativeAddon.updateGeometry(geometry);
          } catch (error) {
            options.logger?.warn(
              "[side-chat-backdrop] geometry update failed",
              asError(error)
            );
            return false;
          }
        },
        setRevealOffset(offsetX) {
          try {
            return nativeAddon.setRevealOffset(offsetX);
          } catch (error) {
            options.logger?.warn(
              "[side-chat-backdrop] reveal update failed",
              asError(error)
            );
            return false;
          }
        },
        rebuild() {
          try {
            return nativeAddon.rebuild();
          } catch (error) {
            options.logger?.warn("[side-chat-backdrop] rebuild failed", asError(error));
            return false;
          }
        },
        detach() {
          try {
            nativeAddon.detach();
          } catch (error) {
            options.logger?.warn("[side-chat-backdrop] detach failed", asError(error));
          }
        },
      };
    } catch (error) {
      lastError = asError(error);
    }
  }

  const loadError =
    lastError ??
    new Error(
      `Side Chat backdrop addon was not found. Checked: ${candidates.join(", ")}`
    );
  options.logger?.warn("[side-chat-backdrop] native addon unavailable", loadError);
  return makeUnavailableAddon(loadError);
}
