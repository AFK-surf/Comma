import { arch as currentArch, platform as currentPlatform } from "node:process";
import { resolve } from "node:path";
import { getCommaReleaseConfig } from "../src/release-config";

export const notchBinaryName = "NotchHost";
export const micCaptureBinaryName = "MicCaptureHost";
export const quickChatBinaryName = "QuickChatHost";
/** Quick Chat on Windows (native/windows/QuickChatHost), with the face it sets words in beside it. */
export const windowsQuickChatBinaryName = "QuickChatHost.exe";
export const windowsQuickChatFontName = "InterVariable.woff2";
export const macAppsBinaryName = "MacAppsHost";
export const sleepGuardBinaryName = "CommaSleepGuard";
export const sleepGuardAddonName = "comma-sleep-guard.node";
export const menuBarAppName = "CommaMenuBarHost";
export const fileApplicationsAddonName = "comma-file-applications.node";
export const notificationAuthorizationAddonName =
  "comma-notification-authorization.node";
export const fontFamiliesAddonName = "comma-font-families.node";
export const keychainPasswordAddonName = "comma-keychain-password.node";
export const cableScannerAddonName = "comma-cable-scanner.node";
export const computerUseAppName = `${getCommaReleaseConfig().productName} Computer Use`;
export const computerUseProductName = "CommaComputerUseDaemon";

/**
 * The menu-bar helper keeps the bundle id it had when it also ran Side Chat:
 * macOS keeps the item's place in the menu bar and its Menu Bar setting by it.
 */
export function menuBarHostBundleId(appBundleId: string) {
  return `${appBundleId}.side-chat`;
}

export function nativeDistRoot(appDir: string) {
  return resolve(appDir, "dist/native");
}

export function sharedMacOSNativeDistDir(appDir: string) {
  return resolve(nativeDistRoot(appDir), "macos");
}

export function platformNativeDistDir(
  appDir: string,
  platform: string = currentPlatform,
  arch: string = currentArch
) {
  return resolve(nativeDistRoot(appDir), platform, arch);
}

/** The station release (systems/station/scripts/bundle.sh's DIR): one for every architecture's build. */
export function stationDistDir(appDir: string) {
  return resolve(nativeDistRoot(appDir), "station");
}

/** The station's mesh addon (bundle.sh: `station/mesh.node`): the client core's endpoint to stations is on it. */
export function stationMeshAddonDistPath(appDir: string) {
  return resolve(stationDistDir(appDir), "station", "mesh.node");
}

export function stationLauncherDistPath(
  appDir: string,
  platform: string = currentPlatform
) {
  return resolve(
    stationDistDir(appDir),
    "mesh/target/release",
    platform === "win32" ? "stillfail-station.exe" : "stillfail-station"
  );
}

/** The synchronicity node daemon and its CLI: one binary, shipped beside the station. */
export function synchBinaryName(platform: string = currentPlatform) {
  return platform === "win32" ? "synch.exe" : "synch";
}

export function synchBinaryPath(
  appDir: string,
  platform: string = currentPlatform,
  arch: string = currentArch
) {
  return resolve(
    platformNativeDistDir(appDir, platform, arch),
    synchBinaryName(platform)
  );
}

export function notchHostDistPath(appDir: string) {
  return resolve(sharedMacOSNativeDistDir(appDir), notchBinaryName);
}

export function menuBarHostDistAppPath(appDir: string) {
  return resolve(sharedMacOSNativeDistDir(appDir), `${menuBarAppName}.app`);
}

export function menuBarHostExecutablePath(appDir: string) {
  return resolve(menuBarHostDistAppPath(appDir), "Contents/MacOS", menuBarAppName);
}

export function fileApplicationsAddonDistPath(appDir: string) {
  return resolve(sharedMacOSNativeDistDir(appDir), fileApplicationsAddonName);
}

export function notificationAuthorizationAddonDistPath(appDir: string) {
  return resolve(sharedMacOSNativeDistDir(appDir), notificationAuthorizationAddonName);
}

export function fontFamiliesAddonDistPath(appDir: string) {
  return resolve(sharedMacOSNativeDistDir(appDir), fontFamiliesAddonName);
}

export function cableScannerAddonDistPath(appDir: string) {
  return resolve(sharedMacOSNativeDistDir(appDir), cableScannerAddonName);
}

export function keychainPasswordAddonDistPath(appDir: string) {
  return resolve(sharedMacOSNativeDistDir(appDir), keychainPasswordAddonName);
}

export function computerUseDistAppPath(
  appDir: string,
  platform: string = currentPlatform,
  arch: string = currentArch
) {
  return resolve(
    platformNativeDistDir(appDir, platform, arch),
    "native/macos",
    `${computerUseAppName}.app`
  );
}

export function packagedNotchHostPath(appBundle: string) {
  return resolve(appBundle, "Contents/Resources/native/macos", notchBinaryName);
}

export function packagedQuickChatHostPath(appBundle: string) {
  return resolve(appBundle, "Contents/Resources/native/macos", quickChatBinaryName);
}

export function packagedMenuBarHostAppPath(appBundle: string) {
  return resolve(appBundle, "Contents/Resources/native/macos", `${menuBarAppName}.app`);
}

export function packagedNotificationAuthorizationAddonPath(appBundle: string) {
  return resolve(
    appBundle,
    "Contents/Resources/native/macos",
    notificationAuthorizationAddonName
  );
}

export function packagedComputerUseAppPath(
  appBundle: string,
  platform: string = currentPlatform,
  arch: string = currentArch
) {
  return resolve(
    appBundle,
    "Contents/Resources/native",
    platform,
    arch,
    "native/macos",
    `${computerUseAppName}.app`
  );
}

export function sleepGuardDistPath(appDir: string) {
  return resolve(sharedMacOSNativeDistDir(appDir), sleepGuardBinaryName);
}

export function sleepGuardAddonDistPath(appDir: string) {
  return resolve(sharedMacOSNativeDistDir(appDir), sleepGuardAddonName);
}

export function packagedSleepGuardPath(appBundle: string) {
  return resolve(appBundle, "Contents/Resources/native/macos", sleepGuardBinaryName);
}

export function micCaptureHostDistPath(appDir: string) {
  return resolve(sharedMacOSNativeDistDir(appDir), micCaptureBinaryName);
}

export function windowsQuickChatDistPath(appDir: string, arch: string = currentArch) {
  return resolve(
    platformNativeDistDir(appDir, "win32", arch),
    windowsQuickChatBinaryName
  );
}

export function quickChatHostDistPath(appDir: string) {
  return resolve(sharedMacOSNativeDistDir(appDir), quickChatBinaryName);
}

/** The Mac apps MCP server (native/macos/MacAppsHost). */
export function macAppsHostDistPath(appDir: string) {
  return resolve(sharedMacOSNativeDistDir(appDir), macAppsBinaryName);
}
