// Starts a synchronicity node from the binary `build:native:synch` fetched for
// this platform, in a throwaway data directory, asks it who it is, then runs
// Comma's direct-control integration against that same binary. The release
// archive's digest was checked when it was fetched; this proves both that the
// binary runs on the shipping platform and that Comma speaks its pinned protocol.
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const require = createRequire(import.meta.url);
const vitest = join(dirname(require.resolve("vitest/package.json")), "vitest.mjs");

const platform = process.platform;
const arch = process.arch;
const binary = join(
  process.cwd(),
  "apps/electron/dist/native",
  platform,
  arch,
  platform === "win32" ? "synch.exe" : "synch"
);
if (!existsSync(binary)) {
  console.error(
    `no synch binary at ${binary}; run pnpm --filter @comma/electron build:native:synch first`
  );
  process.exit(1);
}
const dataDir = mkdtempSync(join(tmpdir(), "comma-synch-smoke-"));
const run = (args) =>
  execFileSync(binary, [...args, "--data-dir", dataDir], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
let daemon = false;
try {
  console.log(run(["--version"]).trim());
  run(["init"]);
  // `id` answers from the running daemon, so this is the daemon coming up
  // and going down on this platform, not only the binary being executable.
  run(["daemon", "start"]);
  daemon = true;
  const id = run(["id"]);
  const origin = id.split("\n").find((line) => line.startsWith("origin:"));
  if (!origin?.includes("key:")) {
    console.error(`synch id did not report an origin key:\n${id}`);
    process.exit(1);
  }
  console.log(origin.trim());
} finally {
  if (daemon) run(["daemon", "stop"]);
  // Windows keeps the stopped daemon's files open a moment longer; the
  // retries cover that. A directory that still will not go is left to the
  // runner — what this smoke answers is whether the daemon ran.
  try {
    rmSync(dataDir, { force: true, maxRetries: 10, recursive: true, retryDelay: 200 });
  } catch (error) {
    console.warn(
      `left ${dataDir} behind: ${error instanceof Error ? error.message : String(error)}`
    );
  }
}

// Exercise Comma's own gRPC-over-local-socket client against this exact pinned
// binary too. The test covers metadata authentication, typed commands,
// multi-chunk Put/Read above the renderer ceiling, and daemon token rotation.
execFileSync(
  process.execPath,
  [
    vitest,
    "run",
    "apps/electron/src/main/test/synchronicity-control.test.ts",
    "--config",
    "vitest.config.ts",
  ],
  {
    cwd: process.cwd(),
    env: { ...process.env, COMMA_SYNCH_CONTROL_TEST_BINARY: binary },
    stdio: "inherit",
  }
);
