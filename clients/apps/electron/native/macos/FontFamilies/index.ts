import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { resolve } from "node:path";

export const fontFamiliesAddonFileName = "comma-font-families.node";

type NativeFontFamiliesAddon = {
  familyNames(): Promise<string[]>;
};

export type FontFamiliesAddon = {
  readonly loaded: boolean;
  readonly binaryPath?: string;
  readonly loadError?: Error;
  /** Installed family names, or null where this addon cannot answer. */
  familyNames(): Promise<string[] | null>;
};

type LoadFontFamiliesAddonOptions = {
  binaryPath?: string;
  isPackaged?: boolean;
  logger?: Pick<Console, "warn">;
  platform?: NodeJS.Platform;
};

function asError(error: unknown) {
  return error instanceof Error ? error : new Error(String(error));
}

function isNativeAddon(value: unknown): value is NativeFontFamiliesAddon {
  return (
    typeof value === "object" &&
    value !== null &&
    typeof (value as Partial<NativeFontFamiliesAddon>).familyNames === "function"
  );
}

export function fontFamiliesCandidateBinaryPaths({
  cwd = process.cwd(),
  environmentPath = process.env.COMMA_FONT_FAMILIES_PATH,
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
  // Explicit/test and environment overrides are exclusive, as for the other
  // Node-API addons: a binary Comma is pointed at answers alone.
  if (explicitPath) return [explicitPath];
  if (!isPackaged && environmentPath) return [environmentPath];

  const resourcesCandidate = resourcesPath
    ? resolve(resourcesPath, "native/macos", fontFamiliesAddonFileName)
    : undefined;
  if (isPackaged) return resourcesCandidate ? [resourcesCandidate] : [];

  const gypOutput = "native/macos/FontFamilies/build";
  const developmentCandidates = [
    resourcesCandidate,
    resolve(cwd, "dist/native/macos", fontFamiliesAddonFileName),
    resolve(cwd, "apps/electron/dist/native/macos", fontFamiliesAddonFileName),
    ...["Debug", "Release"].flatMap((configuration) => [
      resolve(cwd, gypOutput, configuration, "comma_font_families.node"),
      resolve(
        cwd,
        "apps/electron",
        gypOutput,
        configuration,
        "comma_font_families.node"
      ),
    ]),
  ];
  return [
    ...new Set(developmentCandidates.filter((path): path is string => Boolean(path))),
  ];
}

function makeUnavailableAddon(error: Error): FontFamiliesAddon {
  return {
    loaded: false,
    loadError: error,
    familyNames: () => Promise.resolve(null),
  };
}

export function loadFontFamiliesAddon(
  options: LoadFontFamiliesAddonOptions = {}
): FontFamiliesAddon {
  if ((options.platform ?? process.platform) !== "darwin") {
    return makeUnavailableAddon(
      new Error("The font families addon is only available on macOS.")
    );
  }

  // Forge bundles Main as CommonJS, where Vite empties `import.meta`; the
  // candidate paths are absolute, so any absolute base resolves them.
  const require = createRequire(
    resolve(process.cwd(), "comma-font-families-loader.cjs")
  );
  const candidates = fontFamiliesCandidateBinaryPaths({
    ...(options.binaryPath !== undefined ? { explicitPath: options.binaryPath } : {}),
    ...(options.isPackaged !== undefined ? { isPackaged: options.isPackaged } : {}),
  });
  let lastError: Error | undefined;

  for (const binaryPath of candidates) {
    if (!existsSync(binaryPath)) continue;
    try {
      const nativeAddon: unknown = require(binaryPath);
      if (!isNativeAddon(nativeAddon)) {
        throw new Error(`Font families addon at ${binaryPath} has an invalid API.`);
      }
      return {
        loaded: true,
        binaryPath,
        familyNames: () => nativeAddon.familyNames(),
      };
    } catch (error) {
      lastError = asError(error);
    }
  }

  const loadError =
    lastError ??
    new Error(`Font families addon was not found. Checked: ${candidates.join(", ")}`);
  options.logger?.warn("[font-families] native addon unavailable", loadError);
  return makeUnavailableAddon(loadError);
}
