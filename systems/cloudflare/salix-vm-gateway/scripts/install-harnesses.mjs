import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { createReadStream, readFileSync, mkdtempSync, mkdirSync, rmSync, renameSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Build-time dependencies use the existing release lock and its npm integrity.
// This script does not run during VM wake or archive.
const lock = JSON.parse(readFileSync(process.argv[2], "utf8"));
const prefix = "/opt/salix/default-harness";
const staging = mkdtempSync(join(tmpdir(), "salix-harness-build-"));
const environment = { ...process.env, HOME: join(staging, "home"),
  npm_config_cache: join(staging, "npm-cache"), DISABLE_AUTOUPDATER: "1" };
mkdirSync(environment.HOME);
function run(command, args) {
  return execFileSync(command, args, { env: environment, stdio: ["ignore", "pipe", "inherit"], timeout: 240_000 }).toString().trim();
}
async function download(name, dependency) {
  const path = join(staging, `${name}.tgz`);
  run("curl", ["--fail", "--location", "--silent", "--show-error", "--max-time", "180", dependency.tarball, "--output", path]);
  const hash = createHash("sha512");
  for await (const part of createReadStream(path)) hash.update(part);
  if (`sha512-${hash.digest("base64")}` !== dependency.integrity) throw new Error(`Locked integrity mismatch: ${name}`);
  return path;
}
try {
  if (lock.schemaVersion !== 1 || process.platform !== "linux" || process.arch !== "x64") {
    throw new Error("The CF harness build requires lock schema 1 and Linux amd64");
  }
  const npm = await download("npm", lock.npm);
  const patches = [];
  for (const dependency of Object.values(lock.npmSecurityPatches)) {
    patches.push({ dependency, path: await download(dependency.package, dependency) });
  }
  const codex = await download("codex", lock.codex);
  const pi = await download("pi", lock.pi);
  const claude = await download("claude", lock.claude);
  if (lock.claudeAmd64.version !== lock.claude.version) throw new Error("Claude platform and main package versions differ");
  const claudePlatform = await download("claude-platform", lock.claudeAmd64);
  run("npm", ["install", "--global", "--no-audit", "--no-fund", npm]);
  if (run("npm", ["--version"]) !== lock.npm.version) throw new Error("Locked npm version did not install");
  const npmRoot = join(run("npm", ["root", "--global"]), "npm");
  for (const { dependency, path } of patches) {
    const target = join(npmRoot, "node_modules", dependency.package);
    const unpacked = join(staging, dependency.package);
    mkdirSync(unpacked);
    run("tar", ["-xzf", path, "-C", unpacked, "--strip-components=1"]);
    rmSync(target, { recursive: true, force: true });
    renameSync(unpacked, target);
    if (JSON.parse(readFileSync(join(target, "package.json"), "utf8")).version !== dependency.version) {
      throw new Error(`Locked npm patch did not install: ${dependency.package}`);
    }
  }
  run("npm", ["install", "--global", "--prefix", prefix, "--no-audit", "--no-fund", codex, pi]);
  run("npm", ["install", "--global", "--prefix", prefix, "--no-audit", "--no-fund",
    "--ignore-scripts", "--omit=optional", claude, claudePlatform]);
  run(process.execPath, [join(prefix, "lib/node_modules/@anthropic-ai/claude-code/install.cjs")]);
  for (const provider of ["codex", "claude", "pi"]) {
    const installed = JSON.parse(readFileSync(join(prefix, "lib/node_modules", lock[provider].package, "package.json"), "utf8"));
    if (installed.version !== lock[provider].version) throw new Error(`Locked harness version did not install: ${provider}`);
    console.log(`${provider}: ${run(join(prefix, "bin", provider), ["--version"])}`);
  }
} finally {
  rmSync(staging, { recursive: true, force: true });
}
