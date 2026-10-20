import { join, relative, resolve } from "node:path";
import { describe, expect, it } from "vitest";
import {
  computerUseAppName,
  computerUseDistAppPath,
  menuBarHostBundleId,
  menuBarHostDistAppPath,
  menuBarHostExecutablePath,
  nativeDistRoot,
  notchHostDistPath,
  packagedComputerUseAppPath,
  packagedNotchHostPath,
  packagedMenuBarHostAppPath,
  packagedQuickChatHostPath,
  platformNativeDistDir,
  quickChatHostDistPath,
  stationLauncherDistPath,
} from "../scripts/native-paths";

describe("native release paths", () => {
  const appDir = resolve("/repo/clients/apps/electron");
  const appBundle = resolve("/tmp/Comma.app");

  it("uses the same relative ComputerUse helper path before and after packaging", () => {
    const distHelper = computerUseDistAppPath(appDir, "darwin", "arm64");
    const packagedHelper = packagedComputerUseAppPath(appBundle, "darwin", "arm64");

    expect(relative(nativeDistRoot(appDir), distHelper)).toBe(
      join("darwin", "arm64", "native", "macos", `${computerUseAppName}.app`)
    );
    expect(
      relative(resolve(appBundle, "Contents/Resources/native"), packagedHelper)
    ).toBe(relative(nativeDistRoot(appDir), distHelper));
  });

  it("keeps shared macOS helpers under the native macos resource directory", () => {
    expect(notchHostDistPath(appDir)).toBe(
      resolve(appDir, "dist/native/macos/NotchHost")
    );
    expect(packagedNotchHostPath(appBundle)).toBe(
      resolve(appBundle, "Contents/Resources/native/macos/NotchHost")
    );
    // Main runs Quick Chat from these two places (index.ts).
    expect(quickChatHostDistPath(appDir)).toBe(
      resolve(appDir, "dist/native/macos/QuickChatHost")
    );
    expect(packagedQuickChatHostPath(appBundle)).toBe(
      resolve(appBundle, "Contents/Resources/native/macos/QuickChatHost")
    );
    expect(menuBarHostDistAppPath(appDir)).toBe(
      resolve(appDir, "dist/native/macos/CommaMenuBarHost.app")
    );
    expect(menuBarHostExecutablePath(appDir)).toBe(
      resolve(
        appDir,
        "dist/native/macos/CommaMenuBarHost.app/Contents/MacOS/CommaMenuBarHost"
      )
    );
    expect(packagedMenuBarHostAppPath(appBundle)).toBe(
      resolve(appBundle, "Contents/Resources/native/macos/CommaMenuBarHost.app")
    );
  });

  // macOS keeps the menu-bar item's place and its Menu Bar setting by this id.
  it("keeps the menu-bar helper's earlier bundle identity", () => {
    expect(menuBarHostBundleId("surf.comma.desktop.staging")).toBe(
      "surf.comma.desktop.staging.side-chat"
    );
  });

  it("resolves the platform directory and the bundled station's launcher", () => {
    expect(platformNativeDistDir(appDir, "darwin", "arm64")).toBe(
      resolve(appDir, "dist/native/darwin/arm64")
    );
    expect(stationLauncherDistPath(appDir)).toBe(
      resolve(appDir, "dist/native/station/mesh/target/release/stillfail-station")
    );
  });
});
