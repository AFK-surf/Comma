// The core as one script for the phone apps' Hermes (src/hosts/mobile.ts), then as Hermes bytecode.
//
//   node scripts/mobile-bundle.ts <out.js> [<out.hbc>]
//
// esbuild bundles it to ES2020 with async functions and async generators lowered (Hermes 0.81 compiles neither with
// block scoping on); Babel then makes its classes functions (Hermes 0.81's own classes crash); hermesc compiles the
// result with block scoping, as the engine's runtime is configured. hermesc is React Native's, of the release whose
// Hermes both apps carry (`hermes` in apps/android/gradle/libs.versions.toml): HERMESC names one, otherwise it is
// taken from that release's npm package and kept under node_modules/.cache.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { transformSync } from "@babel/core";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
const repository = resolve(here, "../../../..");

/** The React Native release whose Hermes the apps carry. */
export function hermesVersion(): string {
  const toml = readFileSync(
    join(repository, "clients/apps/android/gradle/libs.versions.toml"),
    "utf8"
  );
  const version = /^hermes = "([^"]+)"$/m.exec(toml)?.[1];
  if (!version) throw new Error("libs.versions.toml names no hermes version");
  return version;
}

/** React Native's Hermes tools for this machine (`hermesc`, `hermes`), fetched once. */
export function hermesTools(): { hermesc: string; hermes: string } {
  if (process.env.HERMESC)
    return {
      hermesc: process.env.HERMESC,
      hermes: join(dirname(process.env.HERMESC), "hermes"),
    };
  const version = hermesVersion();
  const cache = join(repository, "node_modules/.cache/comma-hermes", version);
  const folder =
    process.platform === "darwin"
      ? "osx-bin"
      : process.platform === "win32"
        ? "win64-bin"
        : "linux64-bin";
  const bin = join(cache, "package/sdks/hermesc", folder);
  if (!existsSync(join(bin, "hermesc"))) {
    mkdirSync(cache, { recursive: true });
    execFileSync("npm", ["pack", `react-native@${version}`, "--silent"], {
      cwd: cache,
      stdio: ["ignore", "ignore", "inherit"],
    });
    execFileSync(
      "tar",
      ["-xzf", `react-native-${version}.tgz`, "package/sdks/hermesc"],
      { cwd: cache }
    );
  }
  return { hermesc: join(bin, "hermesc"), hermes: join(bin, "hermes") };
}

/** Bundles the core for Hermes into `out`; given `hbc`, compiles it there too. */
export async function bundle(out: string, hbc?: string): Promise<void> {
  await build({
    entryPoints: [join(here, "../src/hosts/mobile.ts")],
    bundle: true,
    format: "iife",
    platform: "neutral",
    mainFields: ["module", "main"],
    target: "es2020",
    supported: { "async-await": false, "async-generator": false, "for-await": false },
    minify: true,
    legalComments: "none",
    outfile: out,
    logLevel: "warning",
  });
  const lowered = transformSync(readFileSync(out, "utf8"), {
    babelrc: false,
    configFile: false,
    compact: true,
    plugins: ["@babel/plugin-transform-classes"],
  });
  if (!lowered?.code) throw new Error("Babel made nothing of the bundle");
  writeFileSync(out, lowered.code);
  if (hbc)
    execFileSync(
      hermesTools().hermesc,
      ["-emit-binary", "-O", "-w", "-block-scoping", "-out", hbc, out],
      { stdio: "inherit" }
    );
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [out, hbc] = process.argv.slice(2);
  if (!out) throw new Error("usage: mobile-bundle.ts <out.js> [<out.hbc>]");
  mkdirSync(dirname(resolve(out)), { recursive: true });
  if (hbc) mkdirSync(dirname(resolve(hbc)), { recursive: true });
  await bundle(out, hbc);
}
