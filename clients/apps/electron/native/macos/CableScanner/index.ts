import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { resolve } from "node:path";

export const cableScannerAddonFileName = "comma-cable-scanner.node";

/** The Bluetooth state a scan reports; `pending` until macOS knows it. */
export type CableScanBluetoothState =
  | "on"
  | "off"
  | "denied"
  | "unsupported"
  | "pending";

/** The app's Bluetooth permission, read without asking for it. */
export type BluetoothAuthorization =
  | "allowed"
  | "denied"
  | "restricted"
  | "not-determined";

type NativeScanEvent =
  | { type: "state"; state: CableScanBluetoothState }
  | { type: "advert"; data: Buffer };

type NativeCableScannerAddon = {
  authorization(): BluetoothAuthorization;
  start(onEvent: (event: NativeScanEvent) => void): void;
  stop(): void;
};

export interface CableScanListener {
  advert(data: Uint8Array): void;
  state(state: CableScanBluetoothState): void;
}

export type CableScannerAddon = {
  readonly loaded: boolean;
  readonly binaryPath?: string;
  readonly loadError?: Error;
  authorization(): BluetoothAuthorization | "unavailable";
  /**
   * Reports the Bluetooth state and every caBLE advert nearby until `signal`
   * aborts. Concurrent scans share one CoreBluetooth scan. The first scan of
   * the process shows the macOS Bluetooth prompt when the user has not
   * answered it yet.
   */
  scan(listener: CableScanListener, signal: AbortSignal): void;
};

type LoadCableScannerAddonOptions = {
  binaryPath?: string;
  isPackaged?: boolean;
  logger?: Pick<Console, "warn">;
  platform?: NodeJS.Platform;
};

function asError(error: unknown) {
  return error instanceof Error ? error : new Error(String(error));
}

function isNativeAddon(value: unknown): value is NativeCableScannerAddon {
  if (typeof value !== "object" || value === null) return false;
  const addon = value as Partial<NativeCableScannerAddon>;
  return (
    typeof addon.authorization === "function" &&
    typeof addon.start === "function" &&
    typeof addon.stop === "function"
  );
}

export function cableScannerCandidateBinaryPaths({
  cwd = process.cwd(),
  environmentPath = process.env.COMMA_CABLE_SCANNER_PATH,
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
  if (explicitPath) return [explicitPath];
  if (!isPackaged && environmentPath) return [environmentPath];

  const resourcesCandidate = resourcesPath
    ? resolve(resourcesPath, "native/macos", cableScannerAddonFileName)
    : undefined;
  if (isPackaged) return resourcesCandidate ? [resourcesCandidate] : [];

  const gypOutput = "native/macos/CableScanner/build";
  const developmentCandidates = [
    resourcesCandidate,
    resolve(cwd, "dist/native/macos", cableScannerAddonFileName),
    resolve(cwd, "apps/electron/dist/native/macos", cableScannerAddonFileName),
    ...["Debug", "Release"].flatMap((configuration) => [
      resolve(cwd, gypOutput, configuration, "comma_cable_scanner.node"),
      resolve(
        cwd,
        "apps/electron",
        gypOutput,
        configuration,
        "comma_cable_scanner.node"
      ),
      resolve(
        cwd,
        "clients/apps/electron",
        gypOutput,
        configuration,
        "comma_cable_scanner.node"
      ),
    ]),
  ];
  return [
    ...new Set(developmentCandidates.filter((path): path is string => Boolean(path))),
  ];
}

/** One native scan for any number of listeners. */
function sharedScanner(
  native: NativeCableScannerAddon,
  logger: Pick<Console, "warn"> | undefined
): CableScannerAddon["scan"] {
  const listeners = new Set<CableScanListener>();
  let state: CableScanBluetoothState = "pending";
  const onEvent = (event: NativeScanEvent) => {
    if (event.type === "state") state = event.state;
    for (const listener of listeners) {
      if (event.type === "state") listener.state(event.state);
      else listener.advert(event.data);
    }
  };
  return (listener, signal) => {
    if (signal.aborted) return;
    listeners.add(listener);
    if (listeners.size === 1) {
      try {
        native.start(onEvent);
      } catch (error) {
        logger?.warn("[cable-scanner] start failed", asError(error));
        listeners.delete(listener);
        listener.state("unsupported");
        return;
      }
    } else {
      listener.state(state);
    }
    signal.addEventListener(
      "abort",
      () => {
        if (!listeners.delete(listener) || listeners.size > 0) return;
        try {
          native.stop();
        } catch (error) {
          logger?.warn("[cable-scanner] stop failed", asError(error));
        }
      },
      { once: true }
    );
  };
}

function makeUnavailableAddon(error: Error): CableScannerAddon {
  return {
    loaded: false,
    loadError: error,
    authorization: () => "unavailable",
    scan: (listener, signal) => {
      if (!signal.aborted) listener.state("unsupported");
    },
  };
}

export function loadCableScannerAddon(
  options: LoadCableScannerAddonOptions = {}
): CableScannerAddon {
  if ((options.platform ?? process.platform) !== "darwin") {
    return makeUnavailableAddon(
      new Error("The caBLE scanner addon is only available on macOS.")
    );
  }

  // Electron Forge bundles Main as CommonJS, where Vite replaces `import.meta`
  // with an empty object; the candidate paths are absolute.
  const require = createRequire(
    resolve(process.cwd(), "comma-cable-scanner-loader.cjs")
  );
  const candidates = cableScannerCandidateBinaryPaths({
    ...(options.binaryPath !== undefined ? { explicitPath: options.binaryPath } : {}),
    ...(options.isPackaged !== undefined ? { isPackaged: options.isPackaged } : {}),
  });
  let lastError: Error | undefined;

  for (const binaryPath of candidates) {
    if (!existsSync(binaryPath)) continue;
    try {
      const nativeAddon: unknown = require(binaryPath);
      if (!isNativeAddon(nativeAddon)) {
        throw new Error(`caBLE scanner addon at ${binaryPath} has an invalid API.`);
      }
      return {
        loaded: true,
        binaryPath,
        authorization: () => {
          try {
            return nativeAddon.authorization();
          } catch {
            return "unavailable";
          }
        },
        scan: sharedScanner(nativeAddon, options.logger),
      };
    } catch (error) {
      lastError = asError(error);
    }
  }

  const loadError =
    lastError ??
    new Error(`caBLE scanner addon was not found. Checked: ${candidates.join(", ")}`);
  options.logger?.warn("[cable-scanner] native addon unavailable", loadError);
  return makeUnavailableAddon(loadError);
}
