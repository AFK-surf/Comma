import { execFileSync } from "node:child_process";
import { existsSync, globSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";

if (process.platform !== "darwin") throw new Error("AirDrop smoke requires macOS.");
const packaged = process.argv.includes("--packaged");
const candidates = packaged
  ? globSync("apps/electron/out/*/*.app/Contents/Resources/native/darwin/*/opendropkit")
  : [join("apps/electron/dist/native/darwin", process.arch, "opendropkit")];
if (candidates.length !== 1 || !existsSync(candidates[0])) {
  throw new Error(
    "Expected one bundled AirDrop receiver. Run build:native:airdrop or package Electron."
  );
}
const binary = resolve(candidates[0]);
execFileSync("codesign", ["--verify", "--strict", binary]);
execFileSync(binary, ["--help"]);
const require = createRequire(import.meta.url);
const vitest = join(dirname(require.resolve("vitest/package.json")), "vitest.mjs");
const pin = require("../apps/electron/scripts/opendropkit-release.json");
const archive = resolve(
  "apps/electron/.native-cache/opendropkit",
  pin.archives[`darwin/${process.arch}`].archive
);
execFileSync(
  process.execPath,
  [
    vitest,
    "run",
    "apps/electron/src/main/test/airdrop.test.ts",
    "apps/electron/test/opendropkit-release.test.ts",
    "--config",
    "vitest.config.ts",
  ],
  {
    stdio: "inherit",
    env: {
      ...process.env,
      COMMA_AIRDROP_TEST_BINARY: binary,
      ...(existsSync(archive) ? { COMMA_OPENDROPKIT_TEST_ARCHIVE: archive } : {}),
    },
  }
);
