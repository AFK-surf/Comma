import packager from "@electron/packager";
import electronPackage from "electron/package.json";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { electronDownloadCache } from "../scripts/electron-download-cache";
import { macosDisplayNameHook } from "../scripts/macos-display-name";

it.skipIf(process.platform !== "darwin").each([
  { productName: "Comma", executableName: "comma" },
  { productName: "Comma Staging", executableName: "comma-staging" },
])(
  "packages $productName while retaining its lowercase executable",
  async ({ productName, executableName }) => {
    const root = await mkdtemp(join(tmpdir(), "comma-display-name-"));
    try {
      const appDir = join(root, "app");
      await mkdir(appDir);
      await writeFile(
        join(appDir, "package.json"),
        JSON.stringify({ name: "comma", version: "1.0.0", main: "index.js" })
      );
      await writeFile(join(appDir, "index.js"), "require('electron').app.quit();");
      const resource = join(root, "resource.txt");
      await writeFile(resource, "packaged resource");
      const cacheRoot = electronDownloadCache();
      const [output] = await packager({
        dir: appDir,
        out: join(root, "out"),
        name: productName,
        executableName,
        platform: "darwin",
        arch: process.arch,
        electronVersion: electronPackage.version,
        ...(cacheRoot ? { download: { cacheRoot } } : {}),
        extendInfo: { CFBundleDisplayName: productName },
        extraResource: [resource],
        afterCopyExtraResources: [macosDisplayNameHook(productName)],
        prune: false,
      });
      const bundle = join(output!, `${productName}.app`, "Contents");
      const plist = join(bundle, "Info.plist");
      const readKey = (key: string) =>
        execFileSync("/usr/libexec/PlistBuddy", ["-c", `Print :${key}`, plist], {
          encoding: "utf8",
        }).trim();

      expect(readKey("CFBundleDisplayName")).toBe(productName);
      expect(readKey("CFBundleExecutable")).toBe(executableName);
      expect(existsSync(join(bundle, "MacOS", executableName))).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  },
  120_000
);
