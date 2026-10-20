import { join } from "node:path";

import { describe, expect, it } from "vitest";
import { nativeMenuBarExecutableCandidatePaths } from "../native-status-menu";

const executableRelativePath =
  "native/macos/CommaMenuBarHost.app/Contents/MacOS/CommaMenuBarHost";

describe("native menu-bar helper discovery", () => {
  it("resolves Forge's unpackaged .vite/build app path back to electron dist", () => {
    const appPath = "/repo/clients/apps/electron/.vite/build";

    expect(
      nativeMenuBarExecutableCandidatePaths({
        appPath,
        cwd: "/unrelated",
        isPackaged: false,
        resourcesPath: "/resources",
      })
    ).toContain(join("/repo/clients/apps/electron/dist", executableRelativePath));
  });

  it("keeps packaged helper discovery fixed under resources", () => {
    expect(
      nativeMenuBarExecutableCandidatePaths({
        appPath: "/tmp/untrusted-app-path",
        cwd: "/tmp/untrusted-cwd",
        isPackaged: true,
        resourcesPath: "/Applications/Comma.app/Contents/Resources",
      })
    ).toEqual([
      join("/Applications/Comma.app/Contents/Resources", executableRelativePath),
    ]);
  });
});
