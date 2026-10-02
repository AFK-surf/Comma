import type { HookFunction } from "@electron/packager";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { sleepGuardPlistName, sleepGuardServiceName } from "../native/macos/SleepGuard";
import { sleepGuardBinaryName } from "./native-paths";

/**
 * Writes the LaunchDaemon plist `SMAppService.daemon(plistName:)` looks for in
 * `Contents/Library/LaunchDaemons`. It must exist before signing so the code
 * seal covers it.
 */
export function sleepGuardLaunchdHook(
  productName: string,
  appBundleId: string
): HookFunction {
  return (buildPath, _electronVersion, platform, _arch, callback) => {
    if (platform !== "darwin") {
      callback();
      return;
    }
    try {
      const directory = join(
        buildPath,
        `${productName}.app`,
        "Contents",
        "Library",
        "LaunchDaemons"
      );
      mkdirSync(directory, { recursive: true });
      writeFileSync(
        join(directory, sleepGuardPlistName(appBundleId)),
        sleepGuardLaunchdPlist(appBundleId)
      );
      callback();
    } catch (error) {
      callback(error instanceof Error ? error : new Error(String(error)));
    }
  };
}

export function sleepGuardLaunchdPlist(appBundleId: string) {
  const label = sleepGuardServiceName(appBundleId);
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>BundleProgram</key>
  <string>Contents/Resources/native/macos/${sleepGuardBinaryName}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>MachServices</key>
  <dict>
    <key>${label}</key>
    <true/>
  </dict>
  <key>AssociatedBundleIdentifiers</key>
  <array>
    <string>${appBundleId}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>COMMA_SLEEP_GUARD_SERVICE</key>
    <string>${label}</string>
    <key>COMMA_SLEEP_GUARD_CLIENT</key>
    <string>${appBundleId}</string>
  </dict>
</dict>
</plist>
`;
}
