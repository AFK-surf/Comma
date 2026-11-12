// Build-only package fetching. APT still owns resolution and verification.
// apt 2.6/3.0 mirror.cc clears pending metadata before type filtering, so its
// mirror lists cannot keep live mirrors away from every InRelease request.
// https://salsa.debian.org/apt-team/apt/-/blob/2.6.1/methods/mirror.cc#L269-275
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, renameSync, rmSync } from "node:fs";
import { basename, join } from "node:path";
import { tmpdir } from "node:os";

const [snapshot, ...args] = process.argv.slice(2);

function status(result) {
  if (result.error) throw result.error;
  if (result.signal) throw new Error(`APT command stopped by ${result.signal}`);
  return result.status;
}

function recover() {
  if (!/^\d{8}T\d{6}Z$/.test(snapshot ?? "") || !["upgrade", "install"].includes(args[0])) {
    throw new Error("Usage: apt-package-recovery.mjs SNAPSHOT {upgrade|install} [APT arguments]");
  }
  // APT can accept an existing final archive by size. Never reuse that state.
  const archives = mkdtempSync(join(tmpdir(), "apt-package-recovery-"));
  chmodSync(archives, 0o755);
  const cache = ["-o", `Dir::Cache::Archives=${archives}/`];
  const apt = (options, capture = false) => spawnSync("apt-get", [...cache, ...options, ...args], {
    stdio: capture ? ["inherit", "pipe", "inherit"] : "inherit",
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
  });
  try {
    // deb.debian.org first: it serves most of the snapshot's packages with the same
    // bytes, and snapshot.debian.org is often slow or unavailable. APT fetches only
    // what deb.debian.org no longer has from the snapshot.
    mkdirSync(join(archives, "partial"), { mode: 0o755 });
    const plan = apt(["--print-uris", "-o", "Acquire::ForceHash=SHA256"], true);
    const planStatus = status(plan);
    if (planStatus !== 0) {
      process.stdout.write(plan.stdout ?? "");
      return planStatus;
    }
    const packages = [];
    for (const line of plan.stdout.split("\n").filter(line => line.startsWith("'"))) {
      const match = /^'([^']+)' (\S+) ([0-9]+) SHA256:([a-fA-F0-9]{64})$/.exec(line);
      if (!match) throw new Error(`Incomplete APT package description: ${line}`);
      const [, original, filename, size, sha256] = match;
      const uri = new URL(original);
      const path = /^\/archive\/(debian|debian-security)\/([^/]+)\/(pool\/.+\.deb)$/.exec(uri.pathname);
      if (!["http:", "https:"].includes(uri.protocol) || uri.hostname !== "snapshot.debian.org" ||
          uri.port || uri.username || uri.password || uri.search || uri.hash ||
          !path || path[2] !== snapshot || basename(filename) !== filename || !filename.endsWith(".deb") ||
          !Number.isSafeInteger(Number(size)) || Number(size) <= 0) {
        throw new Error(`Cannot recover a package outside the locked snapshot: ${original}`);
      }
      packages.push({ filename, size, sha256, uri: `http://deb.debian.org/${path[1]}/${path[3]}` });
    }
    // Validate the complete native plan before fetching any alternate bytes.
    let fetched = 0;
    for (const pkg of packages) {
      const partial = join(archives, "partial", pkg.filename);
      const download = spawnSync("/usr/lib/apt/apt-helper", [
        "download-file", pkg.uri, partial, `SHA256:${pkg.sha256}`, `Checksum-FileSize:${pkg.size}`,
      ], { stdio: ["inherit", "ignore", "ignore"] });
      if (status(download) === 0) {
        renameSync(partial, join(archives, pkg.filename));
        fetched += 1;
      } else {
        rmSync(partial, { force: true });
      }
    }
    console.log(`APT package recovery: ${fetched} of ${packages.length} packages from deb.debian.org`);
    if (fetched < packages.length) {
      const downloadStatus = status(apt(["--download-only"]));
      if (downloadStatus !== 0) return downloadStatus;
    }
    return status(apt(["--no-download"]));
  } finally {
    rmSync(archives, { recursive: true, force: true });
  }
}

try {
  process.exitCode = recover();
} catch (error) {
  console.error(`APT package recovery: ${error.message}`);
  process.exitCode = 1;
}
