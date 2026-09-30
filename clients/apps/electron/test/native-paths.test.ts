import { join, relative, resolve } from "node:path";
import { describe, expect, it } from "vitest";
import {
  computerUseAppName,
  computerUseDistAppPath,
  nativeDistRoot,
  notchHostDistPath,
  packagedComputerUseAppPath,
  packagedNotchHostPath,
  packagedSideChatHostAppPath,
  platformNativeDistDir,
  salixConnectBinaryName,
  salixConnectBinaryPath,
  sideChatHostDistAppPath,
  sideChatHostBundleId,
  sideChatHostExecutablePath,
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
    expect(sideChatHostDistAppPath(appDir)).toBe(
      resolve(appDir, "dist/native/macos/CommaSideChatHost.app")
    );
    expect(sideChatHostExecutablePath(appDir)).toBe(
      resolve(
        appDir,
        "dist/native/macos/CommaSideChatHost.app/Contents/MacOS/CommaSideChatHost"
      )
    );
    expect(packagedSideChatHostAppPath(appBundle)).toBe(
      resolve(appBundle, "Contents/Resources/native/macos/CommaSideChatHost.app")
    );
  });

  it("derives the Side Chat helper identity from the release bundle identity", () => {
    expect(sideChatHostBundleId("surf.comma.desktop.staging")).toBe(
      "surf.comma.desktop.staging.side-chat"
    );
  });

  it("resolves platform salix-connect binaries under the arch-specific directory", () => {
    expect(salixConnectBinaryName("darwin")).toBe("salix-connect");
    expect(salixConnectBinaryName("win32")).toBe("salix-connect.exe");
    expect(platformNativeDistDir(appDir, "darwin", "arm64")).toBe(
      resolve(appDir, "dist/native/darwin/arm64")
    );
    expect(salixConnectBinaryPath(appDir, "win32", "x64")).toBe(
      resolve(appDir, "dist/native/win32/x64/salix-connect.exe")
    );
  });
});
