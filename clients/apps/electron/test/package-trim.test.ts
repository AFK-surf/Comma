import {
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  linkUnspokenChromiumLocales,
  trimVelopackNatives,
} from "../scripts/package-trim";

const roots: string[] = [];

function scratch() {
  const root = mkdtempSync(join(tmpdir(), "comma-package-trim-"));
  roots.push(root);
  return root;
}

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { force: true, recursive: true });
});

describe("trimVelopackNatives", () => {
  const natives = [
    "velopack_nodeffi_linux_arm64_gnu.node",
    "velopack_nodeffi_linux_x64_gnu.node",
    "velopack_nodeffi_osx.node",
    "velopack_nodeffi_win_arm64_msvc.node",
    "velopack_nodeffi_win_x64_msvc.node",
    "velopack_nodeffi_win_x86_msvc.node",
  ];

  function velopackPackage() {
    const packageDir = scratch();
    const nativeDir = join(packageDir, "lib", "native");
    mkdirSync(nativeDir, { recursive: true });
    for (const file of natives) writeFileSync(join(nativeDir, file), file);
    return { packageDir, nativeDir };
  }

  it("keeps only the target's binary", () => {
    const { packageDir, nativeDir } = velopackPackage();
    trimVelopackNatives(packageDir, "win32", "ia32");
    expect(readdirSync(nativeDir)).toEqual(["velopack_nodeffi_win_x86_msvc.node"]);
  });

  it("keeps them all for a target velopack does not name", () => {
    const { packageDir, nativeDir } = velopackPackage();
    trimVelopackNatives(packageDir, "freebsd", "x64");
    expect(readdirSync(nativeDir).toSorted()).toEqual(natives);
  });
});

describe("linkUnspokenChromiumLocales", () => {
  function frameworkResources(locales: string[]) {
    const resources = scratch();
    for (const locale of locales) {
      mkdirSync(join(resources, `${locale}.lproj`));
      writeFileSync(join(resources, `${locale}.lproj`, "locale.pak"), locale);
    }
    return resources;
  }

  it("points the languages Comma does not speak at the English strings", () => {
    const resources = frameworkResources([
      "de",
      "de_FEMININE",
      "en",
      "en_GB",
      "ja",
      "zh_CN",
      "zh_TW",
    ]);
    linkUnspokenChromiumLocales(resources);

    for (const locale of ["de", "ja"]) {
      const pak = join(resources, `${locale}.lproj`, "locale.pak");
      expect(lstatSync(pak).isSymbolicLink()).toBe(true);
      expect(readlinkSync(pak)).toBe(join("..", "en.lproj", "locale.pak"));
      expect(readFileSync(pak, "utf8")).toBe("en");
    }
    for (const locale of ["de_FEMININE", "en", "en_GB", "zh_CN", "zh_TW"]) {
      const pak = join(resources, `${locale}.lproj`, "locale.pak");
      expect(lstatSync(pak).isSymbolicLink()).toBe(false);
      expect(readFileSync(pak, "utf8")).toBe(locale);
    }
  });

  it("can run again over its own result", () => {
    const resources = frameworkResources(["de", "en"]);
    linkUnspokenChromiumLocales(resources);
    linkUnspokenChromiumLocales(resources);
    expect(readFileSync(join(resources, "de.lproj", "locale.pak"), "utf8")).toBe("en");
  });

  it("refuses a framework without English strings", () => {
    const resources = frameworkResources(["de"]);
    expect(() => linkUnspokenChromiumLocales(resources)).toThrow(
      /No English Chromium locale/
    );
  });
});
