import type { HookFunction } from "@electron/packager";
import { execFile } from "node:child_process";
import { join } from "node:path";

export function macosDisplayNameHook(productName: string): HookFunction {
  return (buildPath, _electronVersion, platform, _arch, callback) => {
    if (platform !== "darwin" && platform !== "mas") {
      callback();
      return;
    }

    // Packager overwrites extendInfo with the executable name. Restore the display name before signing.
    execFile(
      "/usr/libexec/PlistBuddy",
      [
        "-c",
        `Set :CFBundleDisplayName ${productName}`,
        join(buildPath, `${productName}.app`, "Contents", "Info.plist"),
      ],
      (error) => callback(error ?? undefined)
    );
  };
}
