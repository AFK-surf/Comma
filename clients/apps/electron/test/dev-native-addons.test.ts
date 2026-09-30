import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  devNativeAddons,
  ensureDevNativeAddons,
  missingDevNativeAddons,
} from "../scripts/dev-native-addons";

describe("from-source native addons", () => {
  let appDir: string;
  beforeEach(() => {
    appDir = mkdtempSync(join(tmpdir(), "comma-dev-native-addons-"));
  });
  afterEach(() => {
    rmSync(appDir, { force: true, recursive: true });
  });

  it("builds every addon a checkout without dist/native is missing", () => {
    const built: string[] = [];
    const missing = ensureDevNativeAddons({
      appDir,
      env: {},
      build: (dir, flag) => {
        expect(dir).toBe(appDir);
        built.push(flag);
      },
    });
    expect(missing.map((addon) => addon.buildFlag)).toEqual([
      "--file-applications-only",
      "--notification-authorization-only",
      "--font-families-only",
    ]);
    expect(built).toEqual(missing.map((addon) => addon.buildFlag));
  });

  it("builds only what is absent and nothing once every addon is present", () => {
    const [fileApplications, notificationAuthorization, fontFamilies] =
      devNativeAddons(appDir);
    mkdirSync(dirname(fileApplications!.output), { recursive: true });
    writeFileSync(fileApplications!.output, "");
    writeFileSync(fontFamilies!.output, "");

    const built: string[] = [];
    ensureDevNativeAddons({ appDir, env: {}, build: (_dir, flag) => built.push(flag) });
    expect(built).toEqual([notificationAuthorization!.buildFlag]);

    writeFileSync(notificationAuthorization!.output, "");
    expect(missingDevNativeAddons(appDir)).toEqual([]);
    expect(
      ensureDevNativeAddons({
        appDir,
        env: {},
        build: () => {
          throw new Error("nothing to build");
        },
      })
    ).toEqual([]);
  });

  it("leaves an explicit COMMA_SKIP_NATIVE_BUILD=1 run alone", () => {
    const missing = ensureDevNativeAddons({
      appDir,
      env: { COMMA_SKIP_NATIVE_BUILD: "1" },
      build: () => {
        throw new Error("must not build");
      },
    });
    expect(missing).toHaveLength(3);
  });
});
