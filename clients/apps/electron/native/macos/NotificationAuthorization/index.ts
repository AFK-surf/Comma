import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { resolve } from "node:path";

export const notificationAuthorizationAddonFileName =
  "comma-notification-authorization.node";

/**
 * macOS `UNAuthorizationStatus` by name, plus `unavailable` for a process that
 * has no bundle to ask for, an unbuilt addon, or a failed query.
 */
export type NotificationAuthorizationStatus =
  | "notDetermined"
  | "denied"
  | "authorized"
  | "provisional"
  | "unavailable";

/** What the app icon shows after a badge update; `unavailable` as above. */
export type NotificationBadgeResult = "shown" | "cleared" | "unavailable";

type NativeNotificationAuthorizationAddon = {
  authorizationStatus(): Promise<NotificationAuthorizationStatus>;
  requestAuthorization(): Promise<NotificationAuthorizationStatus>;
  setBadgeCount(count: number): Promise<NotificationBadgeResult>;
};

export type NotificationAuthorizationAddon = {
  readonly loaded: boolean;
  readonly binaryPath?: string;
  readonly loadError?: Error;
  /** The current status, read without asking the user anything. */
  authorizationStatus(): Promise<NotificationAuthorizationStatus>;
  /**
   * Asks the OS for permission to post banners and resolves with the status
   * the answer leaves behind. The system prompt appears only while the status
   * is `notDetermined`; a decided status answers from the record at once, so
   * asking before every first banner costs nothing.
   */
  requestAuthorization(): Promise<NotificationAuthorizationStatus>;
  /**
   * Shows the count on the app icon, or clears it at zero. With "Badge
   * application icon" off in System Settings the badge is cleared instead.
   */
  setBadgeCount(count: number): Promise<NotificationBadgeResult>;
};

type LoadNotificationAuthorizationAddonOptions = {
  binaryPath?: string;
  isPackaged?: boolean;
  logger?: Pick<Console, "warn">;
  platform?: NodeJS.Platform;
};

function asError(error: unknown) {
  return error instanceof Error ? error : new Error(String(error));
}

function isNativeAddon(value: unknown): value is NativeNotificationAuthorizationAddon {
  if (typeof value !== "object" || value === null) return false;
  const addon = value as Partial<NativeNotificationAuthorizationAddon>;
  return (
    typeof addon.authorizationStatus === "function" &&
    typeof addon.requestAuthorization === "function" &&
    typeof addon.setBadgeCount === "function"
  );
}

export function notificationAuthorizationCandidateBinaryPaths({
  cwd = process.cwd(),
  environmentPath = process.env.COMMA_NOTIFICATION_AUTHORIZATION_PATH,
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
    ? resolve(resourcesPath, "native/macos", notificationAuthorizationAddonFileName)
    : undefined;
  if (isPackaged) return resourcesCandidate ? [resourcesCandidate] : [];

  const gypOutput = "native/macos/NotificationAuthorization/build";
  const developmentCandidates = [
    resourcesCandidate,
    resolve(cwd, "dist/native/macos", notificationAuthorizationAddonFileName),
    resolve(
      cwd,
      "apps/electron/dist/native/macos",
      notificationAuthorizationAddonFileName
    ),
    ...["Debug", "Release"].flatMap((configuration) => [
      resolve(cwd, gypOutput, configuration, "comma_notification_authorization.node"),
      resolve(
        cwd,
        "apps/electron",
        gypOutput,
        configuration,
        "comma_notification_authorization.node"
      ),
      resolve(
        cwd,
        "clients/apps/electron",
        gypOutput,
        configuration,
        "comma_notification_authorization.node"
      ),
    ]),
  ];
  return [
    ...new Set(developmentCandidates.filter((path): path is string => Boolean(path))),
  ];
}

function makeUnavailableAddon(error: Error): NotificationAuthorizationAddon {
  return {
    loaded: false,
    loadError: error,
    authorizationStatus: () => Promise.resolve("unavailable"),
    requestAuthorization: () => Promise.resolve("unavailable"),
    setBadgeCount: () => Promise.resolve("unavailable"),
  };
}

export function loadNotificationAuthorizationAddon(
  options: LoadNotificationAuthorizationAddonOptions = {}
): NotificationAuthorizationAddon {
  if ((options.platform ?? process.platform) !== "darwin") {
    return makeUnavailableAddon(
      new Error("The notification authorization addon is only available on macOS.")
    );
  }

  // Electron Forge bundles Main as CommonJS, where Vite replaces `import.meta`
  // with an empty object. The addon paths below are absolute, so a stable
  // absolute synthetic filename is sufficient as createRequire's resolution
  // base in both the source-test and bundled runtimes.
  const require = createRequire(
    resolve(process.cwd(), "comma-notification-authorization-loader.cjs")
  );
  const candidates = notificationAuthorizationCandidateBinaryPaths({
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
          `Notification authorization addon at ${binaryPath} has an invalid API.`
        );
      }

      const guarded =
        (query: "authorizationStatus" | "requestAuthorization") =>
        async (): Promise<NotificationAuthorizationStatus> => {
          try {
            return await nativeAddon[query]();
          } catch (error) {
            options.logger?.warn(
              `[notification-authorization] ${query} failed`,
              asError(error)
            );
            return "unavailable";
          }
        };

      return {
        loaded: true,
        binaryPath,
        authorizationStatus: guarded("authorizationStatus"),
        requestAuthorization: guarded("requestAuthorization"),
        setBadgeCount: async (count) => {
          try {
            return await nativeAddon.setBadgeCount(count);
          } catch (error) {
            options.logger?.warn(
              "[notification-authorization] setBadgeCount failed",
              asError(error)
            );
            return "unavailable";
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
      `Notification authorization addon was not found. Checked: ${candidates.join(", ")}`
    );
  options.logger?.warn(
    "[notification-authorization] native addon unavailable",
    loadError
  );
  return makeUnavailableAddon(loadError);
}
