import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { resolve } from "node:path";

export const fileApplicationsAddonFileName = "comma-file-applications.node";

import type { FileApplicationsPlatform } from "../../../src/main/modules/files/open-applications";

type NativeFileApplicationsAddon = FileApplicationsPlatform;

export type FileApplicationsAddon = FileApplicationsPlatform & {
  readonly loaded: boolean;
  readonly binaryPath?: string;
  readonly loadError?: Error;
};

type LoadFileApplicationsAddonOptions = {
  binaryPath?: string;
  isPackaged?: boolean;
  logger?: Pick<Console, "warn">;
  platform?: NodeJS.Platform;
};

function asError(error: unknown) {
  return error instanceof Error ? error : new Error(String(error));
}

function isNativeAddon(value: unknown): value is NativeFileApplicationsAddon {
  return (
    typeof value === "object" &&
    value !== null &&
    [
      "listApplicationsForFileName",
      "listApplicationsForFile",
      "openFileWithApplication",
    ].every((key) => typeof (value as Record<string, unknown>)[key] === "function")
  );
}

export function fileApplicationsCandidateBinaryPaths({
  cwd = process.cwd(),
  environmentPath = process.env.COMMA_FILE_APPLICATIONS_PATH,
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
  // Explicit/test and environment overrides are exclusive, as for the Side
  // Chat backdrop: an operator pointing Comma at one binary must not have a
  // different addon quietly answer for it.
  if (explicitPath) return [explicitPath];
  if (!isPackaged && environmentPath) return [environmentPath];

  const resourcesCandidate = resourcesPath
    ? resolve(resourcesPath, "native/macos", fileApplicationsAddonFileName)
    : undefined;
  if (isPackaged) return resourcesCandidate ? [resourcesCandidate] : [];

  const gypOutput = "native/macos/FileApplications/build";
  const developmentCandidates = [
    resourcesCandidate,
    resolve(cwd, "dist/native/macos", fileApplicationsAddonFileName),
    resolve(cwd, "apps/electron/dist/native/macos", fileApplicationsAddonFileName),
    ...["Debug", "Release"].flatMap((configuration) => [
      resolve(cwd, gypOutput, configuration, "comma_file_applications.node"),
      resolve(
        cwd,
        "apps/electron",
        gypOutput,
        configuration,
        "comma_file_applications.node"
      ),
      resolve(
        cwd,
        "clients/apps/electron",
        gypOutput,
        configuration,
        "comma_file_applications.node"
      ),
    ]),
  ];
  return [
    ...new Set(developmentCandidates.filter((path): path is string => Boolean(path))),
  ];
}

function makeUnavailableAddon(error: Error): FileApplicationsAddon {
  return {
    loaded: false,
    loadError: error,
    listApplicationsForFileName: async () => null,
    listApplicationsForFile: async () => null,
    openFileWithApplication: async () => false,
    copyFileToClipboard: async () => false,
  };
}

export function loadFileApplicationsAddon(
  options: LoadFileApplicationsAddonOptions = {}
): FileApplicationsAddon {
  if ((options.platform ?? process.platform) !== "darwin") {
    return makeUnavailableAddon(
      new Error("The file applications addon is only available on macOS.")
    );
  }

  // Electron Forge bundles Main as CommonJS, where Vite replaces `import.meta`
  // with an empty object. The addon paths below are absolute, so a stable
  // absolute synthetic filename is sufficient as createRequire's resolution
  // base in both the source-test and bundled runtimes.
  const require = createRequire(
    resolve(process.cwd(), "comma-file-applications-loader.cjs")
  );
  const candidates = fileApplicationsCandidateBinaryPaths({
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
        throw new Error(`File applications addon at ${binaryPath} has an invalid API.`);
      }

      return {
        loaded: true,
        binaryPath,
        listApplicationsForFileName: (fileName) =>
          nativeAddon.listApplicationsForFileName(fileName),
        listApplicationsForFile: (path) => nativeAddon.listApplicationsForFile(path),
        copyFileToClipboard: async (path) =>
          nativeAddon.copyFileToClipboard?.(path) ?? false,
        openFileWithApplication: (path, applicationPath) =>
          nativeAddon.openFileWithApplication(path, applicationPath),
      };
    } catch (error) {
      lastError = asError(error);
    }
  }

  const loadError =
    lastError ??
    new Error(
      `File applications addon was not found. Checked: ${candidates.join(", ")}`
    );
  options.logger?.warn("[file-applications] native addon unavailable", loadError);
  return makeUnavailableAddon(loadError);
}
