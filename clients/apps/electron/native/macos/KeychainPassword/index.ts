import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { resolve } from "node:path";

export const keychainPasswordAddonFileName = "comma-keychain-password.node";

export type KeychainPasswordRead =
  | { status: "found"; password: string }
  | { status: "denied" | "missing" | "failed" };

type NativeKeychainPasswordAddon = {
  readGenericPassword(service: string, account: string): Promise<KeychainPasswordRead>;
};

export type KeychainPasswordAddon = {
  readonly loaded: boolean;
  readonly binaryPath?: string;
  readonly loadError?: Error;
  /** A generic keychain item, or `failed` where this addon cannot answer. */
  readGenericPassword(service: string, account: string): Promise<KeychainPasswordRead>;
};

type LoadKeychainPasswordAddonOptions = {
  binaryPath?: string;
  isPackaged?: boolean;
  logger?: Pick<Console, "warn">;
  platform?: NodeJS.Platform;
};

function asError(error: unknown) {
  return error instanceof Error ? error : new Error(String(error));
}

function isNativeAddon(value: unknown): value is NativeKeychainPasswordAddon {
  return (
    typeof value === "object" &&
    value !== null &&
    typeof (value as Partial<NativeKeychainPasswordAddon>).readGenericPassword ===
      "function"
  );
}

export function keychainPasswordCandidateBinaryPaths({
  cwd = process.cwd(),
  environmentPath = process.env.COMMA_KEYCHAIN_PASSWORD_PATH,
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
    ? resolve(resourcesPath, "native/macos", keychainPasswordAddonFileName)
    : undefined;
  if (isPackaged) return resourcesCandidate ? [resourcesCandidate] : [];

  const gypOutput = "native/macos/KeychainPassword/build";
  const developmentCandidates = [
    resourcesCandidate,
    resolve(cwd, "dist/native/macos", keychainPasswordAddonFileName),
    resolve(cwd, "apps/electron/dist/native/macos", keychainPasswordAddonFileName),
    ...["Debug", "Release"].flatMap((configuration) => [
      resolve(cwd, gypOutput, configuration, "comma_keychain_password.node"),
      resolve(
        cwd,
        "apps/electron",
        gypOutput,
        configuration,
        "comma_keychain_password.node"
      ),
    ]),
  ];
  return [
    ...new Set(developmentCandidates.filter((path): path is string => Boolean(path))),
  ];
}

function makeUnavailableAddon(error: Error): KeychainPasswordAddon {
  return {
    loaded: false,
    loadError: error,
    readGenericPassword: () => Promise.resolve({ status: "failed" }),
  };
}

export function loadKeychainPasswordAddon(
  options: LoadKeychainPasswordAddonOptions = {}
): KeychainPasswordAddon {
  if ((options.platform ?? process.platform) !== "darwin") {
    return makeUnavailableAddon(
      new Error("The keychain password addon is only available on macOS.")
    );
  }

  // Forge bundles Main as CommonJS, where Vite empties `import.meta`; the
  // candidate paths are absolute, so any absolute base resolves them.
  const require = createRequire(
    resolve(process.cwd(), "comma-keychain-password-loader.cjs")
  );
  const candidates = keychainPasswordCandidateBinaryPaths({
    ...(options.binaryPath !== undefined ? { explicitPath: options.binaryPath } : {}),
    ...(options.isPackaged !== undefined ? { isPackaged: options.isPackaged } : {}),
  });
  let lastError: Error | undefined;

  for (const binaryPath of candidates) {
    if (!existsSync(binaryPath)) continue;
    try {
      const nativeAddon: unknown = require(binaryPath);
      if (!isNativeAddon(nativeAddon)) {
        throw new Error(`Keychain password addon at ${binaryPath} has an invalid API.`);
      }
      return {
        loaded: true,
        binaryPath,
        readGenericPassword: (service, account) =>
          nativeAddon.readGenericPassword(service, account),
      };
    } catch (error) {
      lastError = asError(error);
    }
  }

  const loadError =
    lastError ??
    new Error(
      `Keychain password addon was not found. Checked: ${candidates.join(", ")}`
    );
  options.logger?.warn("[keychain-password] native addon unavailable", loadError);
  return makeUnavailableAddon(loadError);
}
