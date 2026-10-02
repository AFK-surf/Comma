import { arch as currentArch, platform as currentPlatform } from "node:process";
import { resolve } from "node:path";
import { getCommaReleaseConfig } from "../src/release-config";

export const notchBinaryName = "NotchHost";
export const micCaptureBinaryName = "MicCaptureHost";
export const sleepGuardBinaryName = "CommaSleepGuard";
export const sleepGuardAddonName = "comma-sleep-guard.node";
export const sideChatAppName = "CommaSideChatHost";
export const sideChatBackdropAddonName = "comma-side-chat-backdrop.node";
export const fileApplicationsAddonName = "comma-file-applications.node";
export const notificationAuthorizationAddonName =
  "comma-notification-authorization.node";
export const fontFamiliesAddonName = "comma-font-families.node";
export const computerUseAppName = `${getCommaReleaseConfig().productName} Computer Use`;
export const computerUseProductName = "CommaComputerUseDaemon";

export function sideChatHostBundleId(appBundleId: string) {
  return `${appBundleId}.side-chat`;
}

export function salixConnectBinaryName(platform: string = currentPlatform) {
  return platform === "win32" ? "salix-connect.exe" : "salix-connect";
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

export function salixConnectBinaryPath(
  appDir: string,
  platform: string = currentPlatform,
  arch: string = currentArch
) {
  return resolve(
    platformNativeDistDir(appDir, platform, arch),
    salixConnectBinaryName(platform)
  );
}

/** The synchronicity node daemon and its CLI: one binary, shipped beside salix-connect. */
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

export function sideChatHostDistAppPath(appDir: string) {
  return resolve(sharedMacOSNativeDistDir(appDir), `${sideChatAppName}.app`);
}

export function sideChatHostExecutablePath(appDir: string) {
  return resolve(sideChatHostDistAppPath(appDir), "Contents/MacOS", sideChatAppName);
}

export function sideChatBackdropAddonDistPath(appDir: string) {
  return resolve(sharedMacOSNativeDistDir(appDir), sideChatBackdropAddonName);
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

export function packagedSideChatHostAppPath(appBundle: string) {
  return resolve(
    appBundle,
    "Contents/Resources/native/macos",
    `${sideChatAppName}.app`
  );
}

export function packagedSideChatBackdropAddonPath(appBundle: string) {
  return resolve(
    appBundle,
    "Contents/Resources/native/macos",
    sideChatBackdropAddonName
  );
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
