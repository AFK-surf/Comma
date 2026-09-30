import { platform } from "node:process";
import type { CommaOperatingSystem } from "@comma/native-bridge";

export function toCommaOperatingSystem(
  value: NodeJS.Platform | string
): CommaOperatingSystem {
  switch (value) {
    case "darwin":
      return "macos";
    case "win32":
      return "windows";
    case "linux":
      return "linux";
    default:
      return "unknown";
  }
}

export function getOperatingSystem(): CommaOperatingSystem {
  return toCommaOperatingSystem(platform);
}

export function isMacOS(value: NodeJS.Platform | string = platform) {
  return value === "darwin";
}
